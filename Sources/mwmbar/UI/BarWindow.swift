import AppKit
import SwiftUI

@MainActor
final class BarWindow {
  private let window: NSPanel
  private let hosting: NSHostingController<BarWindowRoot>
  private var screen: NSScreen
  nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

  init(
    monitorId: String, screen: NSScreen, state: Bar,
    onSwitchWorkspace: @escaping (String, String) -> Void
  ) {
    let root = BarWindowRoot(
      monitorId: monitorId,
      state: state,
      onSwitchWorkspace: onSwitchWorkspace)
    hosting = NSHostingController(rootView: root)
    hosting.sizingOptions = [.preferredContentSize]
    self.screen = screen

    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentViewController = hosting
    panel.ignoresMouseEvents = false
    window = panel

    hosting.view.postsFrameChangedNotifications = true
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: hosting.view, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reposition() }
    }

    reposition()
    panel.orderFrontRegardless()
  }

  deinit {
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
    }
  }

  func reposition() {
    position(on: screen)
  }

  func setScreen(_ screen: NSScreen) {
    self.screen = screen
    reposition()
  }

  private func position(on screen: NSScreen) {
    let full = screen.frame
    // sizingOptions drives w/h from SwiftUI; we only place the origin. before
    // first layout window.frame.size is zero, and frameDidChange will call us
    // back with a real size.
    let size = window.frame.size
    let w = size.width
    let h = size.height
    if w <= 0 || h <= 0 { return }
    let menubarH = full.height - screen.visibleFrame.height
    let hasNotch = menubarH > 32
    let x: CGFloat
    if hasNotch {
      x = full.origin.x + full.width / 2 + 110
    } else {
      x = full.origin.x + (full.width - w) / 2
    }
    let y = full.origin.y + full.height - menubarH + (menubarH - h) / 2
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  func close() {
    window.close()
  }
}

struct BarWindowRoot: View {
  let monitorId: String
  let state: Bar
  let onSwitchWorkspace: (String, String) -> Void

  var body: some View {
    BarView(monitorId: monitorId, onSwitchWorkspace: onSwitchWorkspace)
      .environment(state)
  }
}
