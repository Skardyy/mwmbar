import AppKit

/// hover triggered peek. 100ms dwell to show from idle; already visible means
/// instant swap to the next hovered workspace. 150ms grace on exit so moving
/// between pills does not flash.
@MainActor
final class PeekController {
  private let service: PeekService
  private let panel: PeekPanel
  private var currentKey: String?
  private var pendingShow: Task<Void, Never>?
  private var pendingHide: Task<Void, Never>?
  private var shown = false

  init(screen: NSScreen, service: PeekService) {
    self.service = service
    self.panel = PeekPanel(screen: screen)
  }

  func setScreen(_ screen: NSScreen) { panel.setScreen(screen) }

  func enter(workspaceId: String, windowIds: [CGWindowID], pillCenterX: CGFloat) {
    Log.bar.debug("peek enter ws=\(workspaceId) ids=\(windowIds) shown=\(shown)")
    let key = workspaceId
    pendingHide?.cancel()
    pendingHide = nil
    if shown {
      if key != currentKey {
        present(key: key, windowIds: windowIds, pillCenterX: pillCenterX)
      }
      return
    }
    pendingShow?.cancel()
    pendingShow = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      if Task.isCancelled { return }
      self?.present(key: key, windowIds: windowIds, pillCenterX: pillCenterX)
    }
  }

  func exit() {
    Log.bar.debug("peek exit shown=\(shown)")
    pendingShow?.cancel()
    pendingShow = nil
    pendingHide = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(30))
      if Task.isCancelled { return }
      self?.dismiss()
    }
  }

  func invalidate(windowId: CGWindowID) {
    service.invalidate(windowId: windowId)
  }

  /// re render the current peek against fresh state. called when the
  /// compositor's live/hidden set changes while a peek is on screen.
  func refreshIfShown() {
    guard shown, let key = currentKey else { return }
    guard let ids = currentIds else { return }
    service.invalidateAll()
    service.capture(windowIds: ids) { [weak self] image in
      guard let self, self.currentKey == key, let image else { return }
      self.panel.show(image: image)
    }
  }

  private var currentIds: [CGWindowID]?

  private func present(key: String, windowIds: [CGWindowID], pillCenterX: CGFloat) {
    currentKey = key
    currentIds = windowIds
    panel.anchorCenterX = pillCenterX
    // panel stays hidden until the first image arrives for this key, so a
    // slow capture does not flash an empty frame.
    panel.hide()
    service.capture(windowIds: windowIds) { [weak self] image in
      guard let self, self.currentKey == key else { return }
      guard let image else {
        Log.bar.warning("peek capture nil for ids=\(windowIds).")
        self.dismiss()
        return
      }
      self.panel.show(image: image)
      self.shown = true
    }
  }

  private func dismiss() {
    panel.hide()
    shown = false
    currentKey = nil
  }
}
