import AppKit
import SwiftUI

@MainActor
final class PeekPanel {
  private let panel: NSPanel
  private let hosting: NSHostingController<PeekView>
  private let state: PeekState
  private var screen: NSScreen
  /// screen x of the pill the peek is for. panel centers on this.
  var anchorCenterX: CGFloat = 0

  init(screen: NSScreen) {
    self.screen = screen
    let state = PeekState()
    self.state = state
    hosting = NSHostingController(rootView: PeekView(state: state))
    let p = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
    p.contentView = hosting.view
    p.ignoresMouseEvents = true
    panel = p
    reshape()
  }

  func show(image: NSImage) {
    state.image = image
    reshape()
    panel.orderFrontRegardless()
  }

  func clear() {
    state.image = nil
  }

  func showPlaceholder() {
    reshape()
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  func setScreen(_ screen: NSScreen) {
    self.screen = screen
    reshape()
  }

  private func reshape() {
    let full = screen.frame
    let menubarH = full.height - screen.visibleFrame.height
    let h = min(full.height * 0.35, 500)
    let imgAspect: CGFloat = {
      if let sz = state.image?.size, sz.width > 0, sz.height > 0 {
        return sz.width / sz.height
      }
      return 16.0 / 9.0
    }()
    let maxW = min(full.width * 0.6, 1200)
    let w = min(h * imgAspect, maxW)
    var x = anchorCenterX - w / 2
    let minX = full.origin.x + 8
    let maxX = full.origin.x + full.width - w - 8
    x = min(max(x, minX), maxX)
    let y = full.origin.y + full.height - menubarH - h - 6
    panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
  }
}

@MainActor
final class PeekState: ObservableObject {
  @Published var image: NSImage?
}

struct PeekView: View {
  @ObservedObject var state: PeekState

  var body: some View {
    Group {
      if let img = state.image {
        Image(nsImage: img)
          .resizable()
          .scaledToFit()
      } else {
        Color.clear
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(BarConfig.containerStroke, lineWidth: 0.5)
        )
    )
  }
}
