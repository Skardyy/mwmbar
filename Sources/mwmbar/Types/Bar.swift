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
