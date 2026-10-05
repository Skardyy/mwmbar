import Atomics
import Foundation
import Observation
import os.lock

/// immutable ui snapshot; written off main, read on main.
struct BarSnapshot: Sendable, Equatable {
  let monitors: [Monitor]
  let focusedWindowId: String?

  static let empty = BarSnapshot(monitors: [], focusedWindowId: nil)
}

/// reference wrapped snapshot so the atomic swap works on a single word.
/// box is immutable; only the atomic reference ever changes.
private final class SnapshotBox: @unchecked Sendable {
  let value: BarSnapshot
  init(_ value: BarSnapshot) { self.value = value }
}

/// observation trigger bumped after every snapshot commit so views outside
/// the observation graph can resubscribe.
@MainActor
@Observable
final class BarGeneration {
  var tick: UInt64 = 0
}

/// merges wm monitor trees with compositor state off main and holds the
/// atomic snapshot. bumps a main actor generation after every change.
final class Invalidator: @unchecked Sendable {
  let generation: BarGeneration
  @MainActor var onLifecycleChange: (() -> Void)?

  nonisolated(unsafe) let tracker: CompositorTracker
  /// atomic reference to the live SnapshotBox (held as UInt bit pattern).
  /// readers do a lock free load; writers passRetained a new box, atomic
  /// exchange, then release the old box on main so readers (always on
  /// main) never dereference a freed pointer within the same runloop.
  private let snapshotPtr: ManagedAtomic<UInt>
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let queue = DispatchQueue(label: "mwmbar.invalidator", qos: .userInteractive)

  private struct State {
    var lastMonitors: [Monitor] = []
    var haveSubmission = false
    var placement: [String: (monitorId: String, workspaceId: String)] = [:]
    var sourceFocusedWindowId: String? = nil
    var trackerLive: [String: CompositorTracker.WindowInfo] = [:]
    var trackerHidden: Set<String> = []
    var trackerFocused: String? = nil
  }

  @MainActor init() {
    self.generation = BarGeneration()
    self.tracker = CompositorTracker()
    let box = SnapshotBox(.empty)
    let raw = Unmanaged.passRetained(box).toOpaque()
    self.snapshotPtr = ManagedAtomic<UInt>(UInt(bitPattern: raw))
    tracker.onChange = { [weak self] in
      MainActor.assumeIsolated {
        self?.onLifecycleChange?()
        self?.ingestTrackerOnMain()
      }
    }
    tracker.onFocusChange = { [weak self] in
      MainActor.assumeIsolated { self?.ingestTrackerOnMain() }
    }
  }

  deinit {
    let raw = snapshotPtr.load(ordering: .relaxed)
    if let ptr = UnsafeRawPointer(bitPattern: raw) {
      Unmanaged<SnapshotBox>.fromOpaque(ptr).release()
    }
  }

  @MainActor func start() {
    tracker.start()
  }

  /// lock free load of the current snapshot. main actor only so the box
  /// cannot be freed under the reader; writers defer old box release to
  /// main for the same reason.
  @MainActor func snapshot() -> BarSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<SnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }

  func submit(monitors: [Monitor], focusedWindowId: String? = nil) {
    PerfTrace.incr("invalidator.submit")
    queue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.lastMonitors = monitors
        s.haveSubmission = true
        s.sourceFocusedWindowId = focusedWindowId
        for m in monitors {
          for ws in m.workspaces {
            for w in ws.windows {
              s.placement[w.id] = (m.id, ws.id)
            }
          }
        }
      }
      self.reevaluate()
    }
  }

  @MainActor func restoreWindow(id: String) {
    tracker.restore(id: id)
  }

  @MainActor func closeWindow(id: String) {
    tracker.close(id: id)
  }

  @MainActor private func ingestTrackerOnMain() {
    let live = tracker.live
    let hidden = tracker.hidden
    let focus = tracker.focusedWindowId
    queue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.trackerLive = live
        s.trackerHidden = hidden
        s.trackerFocused = focus
      }
      self.reevaluate()
    }
  }

  private func reevaluate() {
    let span = PerfTrace.begin("invalidator.reevaluate")
    defer { PerfTrace.end(span) }
    PerfTrace.incr("invalidator.reevaluate")

    let s = state.withLock { $0 }
    guard s.haveSubmission else { return }

    var reinjectByWs: [String: [Window]] = [:]
    let known = Set(s.lastMonitors.flatMap { $0.workspaces.flatMap { $0.windows.map(\.id) } })
    for (id, info) in s.trackerLive where !known.contains(id) {
      guard let place = s.placement[id] else { continue }
      let name = info.name ?? ""
      let bid = info.bundleId ?? ""
      let win = Window(id: id, bundleId: bid, name: name, isHidden: s.trackerHidden.contains(id))
      reinjectByWs["\(place.monitorId)/\(place.workspaceId)", default: []].append(win)
    }

    let filtered = s.lastMonitors.map { monitor in
      var out = monitor
      out.workspaces = monitor.workspaces.map { ws in
        var w = ws
        w.windows = ws.windows.compactMap { overlay($0, state: s) }
        if let extras = reinjectByWs["\(monitor.id)/\(ws.id)"] {
          w.windows.append(contentsOf: extras)
        }
        return w
      }
      return out
    }

    // prefer compositor focus when it points at a live window; otherwise
    // use the source reported focus if any.
    let compositorFocus = s.trackerFocused.flatMap { s.trackerLive[$0] != nil ? $0 : nil }
    let focus = compositorFocus ?? s.sourceFocusedWindowId
    commit(BarSnapshot(monitors: filtered, focusedWindowId: focus))
  }

  private func overlay(_ window: Window, state s: State) -> Window? {
    guard let info = s.trackerLive[window.id] else {
      Log.bar.debug("drop window \(window.id) (\(window.bundleId)): unknown to compositor")
      return nil
    }
    var out = window
    if let bid = info.bundleId { out.bundleId = bid }
    if let name = info.name { out.name = name }
    out.isHidden = s.trackerHidden.contains(window.id)
    return out
  }

  private func commit(_ snap: BarSnapshot) {
    // equality check outside the swap; safe to dereference the current
    // box here because commits are serialized on invalidator.queue and
    // only prior (not current) boxes are ever queued for release.
    let currentRaw = snapshotPtr.load(ordering: .acquiring)
    if let currentPtr = UnsafeRawPointer(bitPattern: currentRaw) {
      let currentValue =
        Unmanaged<SnapshotBox>.fromOpaque(currentPtr).takeUnretainedValue().value
      if currentValue == snap {
        PerfTrace.incr("invalidator.commit.noop")
        return
      }
    }

    let newBox = SnapshotBox(snap)
    let newRaw = Unmanaged.passRetained(newBox).toOpaque()
    let oldRawInt = snapshotPtr.exchange(
      UInt(bitPattern: newRaw), ordering: .acquiringAndReleasing)

    PerfTrace.incr("invalidator.commit")
    PerfTrace.mark("invalidator.commit")
    for m in snap.monitors {
      let ids = m.workspaces.map {
        "\($0.id)(\($0.windows.map { $0.isHidden ? "\($0.id)*" : $0.id }.joined(separator: ",")))"
      }.joined(separator: ",")
      Log.bar.debug(
        "commit monitor \(m.id) ws=\(m.focusedWorkspaceId ?? "nil") "
          + "win=\(snap.focusedWindowId ?? "nil") \(ids)")
    }
    let gen = generation
    Task { @MainActor in
      // release the old box only after the main runloop has yielded past
      // any snapshot reader that was mid flight at exchange time.
      if let oldPtr = UnsafeRawPointer(bitPattern: oldRawInt) {
        Unmanaged<SnapshotBox>.fromOpaque(oldPtr).release()
      }
      gen.tick &+= 1
    }
  }
}
