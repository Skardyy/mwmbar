import Foundation
import Observation

@Observable
@MainActor
final class Bar {
  var monitors: [Monitor] = []
  var focusedWindowId: String?

  @ObservationIgnored private let tracker = CompositorTracker()
  @ObservationIgnored private var invalidator: Invalidator!
  /// fires on any live window set change. consumers that cache per window
  /// data (peek thumbnails, icon snapshots) hook this to drop stale entries.
  @ObservationIgnored var onLifecycleChange: (() -> Void)?

  init() {
    invalidator = Invalidator(tracker: tracker) { [weak self] monitors, focus in
      self?.applyIfChanged(monitors: monitors, focusedWindowId: focus)
    }
    // invalidator installs its own onChange on the tracker in init above.
    // wrap (don't replace) so both the invalidator pipeline and external
    // lifecycle subscribers fire on every tracker tick.
    let inner = tracker.onChange
    tracker.onChange = { [weak self] in
      inner?()
      self?.onLifecycleChange?()
    }
  }

  func start() {
    tracker.start()
  }

  func restoreWindow(id: String) {
    tracker.restore(id: id)
  }

  func closeWindow(id: String) {
    tracker.close(id: id)
  }

  /// submit a candidate monitor tree. the focused window id is resolved
  /// internally and layered onto the tree before it reaches `monitors`.
  func tryUpdate(monitors: [Monitor]) {
    PerfTrace.incr("bar.tryUpdate")
    invalidator.tryUpdate(monitors: monitors)
  }

  private func applyIfChanged(monitors: [Monitor], focusedWindowId: String?) {
    if monitors == self.monitors && focusedWindowId == self.focusedWindowId {
      PerfTrace.incr("bar.commit.noop")
      return
    }
    PerfTrace.incr("bar.commit")
    PerfTrace.mark("bar.commit")
    for m in monitors {
      let ids = m.workspaces.map {
        "\($0.id)(\($0.windows.map { $0.isHidden ? "\($0.id)*" : $0.id }.joined(separator: ",")))"
      }.joined(separator: ",")
      Log.bar.debug(
        "commit monitor \(m.id) ws=\(m.focusedWorkspaceId ?? "nil") "
          + "win=\(focusedWindowId ?? "nil") \(ids)")
    }
    self.monitors = monitors
    self.focusedWindowId = focusedWindowId
  }
}
