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

private final class SnapshotBox: AtomicReference, @unchecked Sendable {
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
  private let snapshotRef: ManagedAtomic<SnapshotBox>
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
    self.snapshotRef = ManagedAtomic<SnapshotBox>(SnapshotBox(.empty))
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

  @MainActor func start() {
    tracker.start()
  }

  @MainActor func snapshot() -> BarSnapshot {
    snapshotRef.load(ordering: .acquiring).value
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
    // equality check against the current snapshot; commits are serialized
    // on invalidator.queue so no racing writer swaps it mid comparison.
    if snapshotRef.load(ordering: .acquiring).value == snap {
      PerfTrace.incr("invalidator.commit.noop")
      return
    }

    snapshotRef.store(SnapshotBox(snap), ordering: .releasing)

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
    Task { @MainActor in gen.tick &+= 1 }
  }
}
