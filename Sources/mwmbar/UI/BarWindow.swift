import AppKit
import SwiftUI

@MainActor
final class BarWindow {
  private let window: NSPanel
  private let hosting: NSHostingController<BarWindowRoot>

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

    position(on: screen)
    panel.orderFrontRegardless()
  }

  func position(on screen: NSScreen) {
    let full = screen.frame
    let contentSize = hosting.preferredContentSize
    let w = max(80, contentSize.width)
    let h = max(22, contentSize.height)
    let menubarH = full.height - screen.visibleFrame.height
    let x = full.origin.x + (full.width - w) / 2
    let y = full.origin.y + full.height - menubarH + (menubarH - h) / 2
    window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
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
