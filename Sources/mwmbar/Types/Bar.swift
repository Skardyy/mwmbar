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

  /// sources call this whenever their view of the world changes. the bar
  /// filters against compositor truth and only republishes if the resulting
  /// tree actually differs from the last render.
  func tryUpdate(monitors: [Monitor], focusedWindowId: String?) {
    invalidator.tryUpdate(monitors: monitors, focusedWindowId: focusedWindowId)
  }

  private func applyIfChanged(monitors: [Monitor], focusedWindowId: String?) {
    if monitors == self.monitors && focusedWindowId == self.focusedWindowId { return }
    self.monitors = monitors
    self.focusedWindowId = focusedWindowId
  }
}
