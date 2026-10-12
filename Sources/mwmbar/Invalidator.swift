import Atomics
import CoreGraphics
import Foundation
import Observation
import os.lock

struct BarSnapshot: Sendable, Equatable {
  let monitors: [Monitor]
  let focusedWindowId: String?

  static let empty = BarSnapshot(monitors: [], focusedWindowId: nil)

  var summary: String {
    monitors.map { m in
      let ids = m.workspaces.map {
        "\($0.id)(\($0.windows.map { $0.isHidden ? "\($0.id)*" : $0.id }.joined(separator: ",")))"
      }.joined(separator: ",")
      return "monitor \(m.id) ws=\(m.focusedWorkspaceId ?? "nil") "
        + "win=\(focusedWindowId ?? "nil") \(ids)"
    }.joined(separator: " | ")
  }
}

private final class SnapshotBox: AtomicReference, @unchecked Sendable {
  let value: BarSnapshot
  init(_ value: BarSnapshot) { self.value = value }
}

@MainActor
@Observable
final class BarGeneration {
  var tick: UInt64 = 0
}

/// merges wm monitor/s with compositor state off main and holds the
/// atomic snapshot. bumps a main actor generation after every change.
final class Invalidator: @unchecked Sendable {
  let generation: BarGeneration
  @MainActor var onLifecycleChange: (() -> Void)?

  let compositor: Compositor
  private let snapshotRef: ManagedAtomic<SnapshotBox>
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let queue = DispatchQueue(label: "mwmbar.invalidator", qos: .userInteractive)

  private struct State {
    var lastMonitors: [Monitor] = []
    var haveWmSubmission = false
    var compositorWindows: [CGWindowID: CompositorWindow] = [:]
    var compositorFocused: CGWindowID? = nil
  }

  @MainActor init() {
    self.generation = BarGeneration()
    self.compositor = Compositor()
    self.snapshotRef = ManagedAtomic<SnapshotBox>(SnapshotBox(.empty))
    compositor.onChange = { [weak self] in
      MainActor.assumeIsolated {
        self?.onLifecycleChange?()
        self?.pullCompositorState()
      }
    }
  }

  @MainActor func start() {
    compositor.start()
    // fetch right away since start is async
    pullCompositorState()
  }

  @MainActor func stop() {
    Log.bar.info("invalidator stop")
    compositor.stop()
    onLifecycleChange = nil
    state.withLock { s in
      s = State()
    }
    snapshotRef.store(SnapshotBox(.empty), ordering: .releasing)
    Task { @MainActor in self.generation.tick &+= 1 }
  }

  @MainActor func snapshot() -> BarSnapshot {
    snapshotRef.load(ordering: .acquiring).value
  }

  func wmSubmit(monitors: [Monitor]) {
    queue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.lastMonitors = monitors
        s.haveWmSubmission = true
      }
      self.rebuildSnapshot()
    }
  }

  @MainActor func unhideWindow(id: String) {
    guard let wid = CGWindowID(id) else { return }
    compositor.unhide(wid: wid)
  }

  @MainActor func closeWindow(id: String) {
    guard let wid = CGWindowID(id) else { return }
    compositor.close(wid: wid)
  }

  @MainActor private func pullCompositorState() {
    let windows = compositor.windows
    let focus = compositor.focusedWid
    queue.async { [weak self] in
      guard let self else { return }
      self.state.withLock { s in
        s.compositorWindows = windows
        s.compositorFocused = focus
      }
      self.rebuildSnapshot()
    }
  }

  private func rebuildSnapshot() {
    let s = state.withLock { $0 }
    guard s.haveWmSubmission else { return }

    // walk the wm tree; drop windows the compositor says do not exist;
    // enrich bundle id and hidden flag from compositor truth.
    let filtered = s.lastMonitors.map { monitor in
      var out = monitor
      out.workspaces = monitor.workspaces.map { ws in
        var w = ws
        w.windows = ws.windows.compactMap { window in
          guard let wid = CGWindowID(window.id), let info = s.compositorWindows[wid] else {
            Log.bar.debug(
              "drop window \(window.id) (\(window.bundleId)): unknown to compositor")
            return nil
          }

          var out = window
          if let bid = info.bundleId { out.bundleId = bid }
          out.isHidden = info.hidden
          return out
        }
        return w
      }
      return out
    }

    let focus: String? = {
      guard let wid = s.compositorFocused, s.compositorWindows[wid] != nil
      else { return nil }
      return String(wid)
    }()
    commit(BarSnapshot(monitors: filtered, focusedWindowId: focus))
  }

  private func commit(_ snap: BarSnapshot) {
    // if same leave, not then swap
    if snapshotRef.load(ordering: .acquiring).value == snap { return }
    snapshotRef.store(SnapshotBox(snap), ordering: .releasing)

    Log.bar.debug("commit \(snap.summary)")

    let gen = generation
    Task { @MainActor in gen.tick &+= 1 }
  }
}
