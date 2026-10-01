import Foundation
import Observation

@Observable
@MainActor
final class Bar {
  var monitors: [Monitor] = []
  var focusedWindowId: String?

  @ObservationIgnored private let tracker = CompositorTracker()
  @ObservationIgnored private var invalidator: Invalidator!

  init() {
    invalidator = Invalidator(tracker: tracker) { [weak self] monitors, focus in
      self?.applyIfChanged(monitors: monitors, focusedWindowId: focus)
    }
  }

  func start() {
    tracker.start()
  }

  func restoreWindow(id: String) {
    tracker.restore(id: id)
  }

  /// callers submit only the monitor/workspace/window tree. focused window id
  /// is tracked separately via the compositor and merged in by the invalidator.
  func tryUpdate(monitors: [Monitor]) {
    invalidator.tryUpdate(monitors: monitors)
  }

  private func applyIfChanged(monitors: [Monitor], focusedWindowId: String?) {
    if monitors == self.monitors && focusedWindowId == self.focusedWindowId { return }
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
