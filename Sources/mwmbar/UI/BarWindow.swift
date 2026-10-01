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
    onSwitchWorkspace: @escaping (String, String) -> Void,
    onRestoreWindow: @escaping (String) -> Void,
    onPeekEnter: @escaping (Workspace, CGFloat) -> Void,
    onPeekExit: @escaping () -> Void
  ) {
    let root = BarWindowRoot(
      monitorId: monitorId,
      state: state,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit)
    hosting = NSHostingController(rootView: root)
    // skip sizingOptions. NSHostingController's own resize path anchors the
    // window in a way that visibly shifts the left edge during width change;
    // instead the frameDidChange handler reshapes the panel manually with a
    // left anchored setFrame.
    self.screen = screen

    // nonactivatingPanel keeps clicks from stealing key status from the user's focused window.
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
    // canJoinAllSpaces: visible on every Space. stationary: no Mission Control
    // shuffle. ignoresCycle: skip cmd tab.
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentViewController = hosting
    panel.ignoresMouseEvents = false
    window = panel

    hosting.view.postsFrameChangedNotifications = true
    // reshape the panel to match SwiftUI's intrinsic size on every layout
    // pass. Y origin is pinned to the menubar, X origin to our anchor, so
    // width grows strictly rightward and the left edge never jumps.
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: hosting.view, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reshapeToContent() }
    }
    reshapeToContent()
    panel.orderFrontRegardless()
  }

  deinit {
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
    }
  }

  func setScreen(_ screen: NSScreen) {
    self.screen = screen
    reshapeToContent()
  }

  private func reshapeToContent() {
    let full = screen.frame
    let menubarH = full.height - screen.visibleFrame.height
    // notched displays reserve a taller menubar (~37pt); non notched sit around 24pt.
    let hasNotch = menubarH > 32
    let content = hosting.view.fittingSize
    let h: CGFloat = max(content.height, 24)
    let w: CGFloat = max(content.width, 60)
    let x: CGFloat
    if hasNotch {
      // 110pt right of center clears the notch cutout on 14/16" MacBooks.
      x = full.origin.x + full.width / 2 + 110
    } else {
      x = full.origin.x + (full.width - w) / 2
    }
    let y = full.origin.y + full.height - menubarH + (menubarH - h) / 2
    window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
  }

  func close() {
    window.close()
  }

  /// screen x of the bar panel's leading edge. consumers add their SwiftUI
  /// local x to this to get a screen coord.
  var originX: CGFloat { window.frame.minX }

}

struct BarWindowRoot: View {
  let monitorId: String
  let state: Bar
  let onSwitchWorkspace: (String, String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void

  var body: some View {
    BarView(
      monitorId: monitorId,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit
    )
    .environment(state)
  }
}
