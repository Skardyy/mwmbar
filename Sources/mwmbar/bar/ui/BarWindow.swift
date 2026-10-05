import AppKit
import SwiftUI

/// hosting view that only hit tests inside the live bar background width.
/// hitWidth is updated via a preference key from the SwiftUI body.
final class BarHostingView<Content: View>: NSHostingView<Content> {
  var hitWidth: CGFloat = 0
  var centered: Bool = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    let w = bounds.width
    let lo: CGFloat
    let hi: CGFloat
    if centered {
      let mid = w / 2
      lo = mid - hitWidth / 2
      hi = mid + hitWidth / 2
    } else {
      lo = 0
      hi = hitWidth
    }
    guard point.x >= lo && point.x <= hi else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
final class BarWindow {
  let screenName: String
  private let window: NSPanel
  private let hosting: BarHostingView<BarWindowRoot>
  private var screen: NSScreen
  private let tint: WallpaperTint
  nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

  init(
    screen: NSScreen, screenName: String, invalidator: Invalidator,
    onSwitchWorkspace: @escaping (String) -> Void,
    onRestoreWindow: @escaping (String) -> Void,
    onPeekEnter: @escaping (Workspace, CGFloat) -> Void,
    onPeekExit: @escaping () -> Void
  ) {
    let hostingRef = HostingRef()
    let displayId =
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
      .uint32Value ?? CGMainDisplayID()
    // sample the top 20% of the display. on notched screens only the right
    // half of that band is meaningful, since the notch itself splits the
    // menubar and the pills live to the right of the notch.
    let full = screen.frame
    let menubarH = full.height - screen.visibleFrame.height
    let hasNotch = menubarH > 32
    let cropFraction =
      hasNotch
      ? CGRect(x: 0.5, y: 0, width: 0.5, height: 0.2)
      : CGRect(x: 0, y: 0, width: 1.0, height: 0.2)
    let tint = WallpaperTint(display: displayId, cropFraction: cropFraction)
    self.tint = tint
    let menubarH0 = screen.frame.height - screen.visibleFrame.height
    let hasNotch0 = menubarH0 > 32
    let root = BarWindowRoot(
      screenName: screenName,
      invalidator: invalidator,
      tint: tint,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit,
      hostingRef: hostingRef,
      centered: !hasNotch0)
    hosting = BarHostingView(rootView: root)
    hostingRef.view = hosting
    // skip sizingOptions. NSHostingController's own resize path anchors the
    // window in a way that visibly shifts the left edge during width change;
    // instead the frameDidChange handler reshapes the panel manually with a
    // left anchored setFrame.
    self.screen = screen
    self.screenName = screenName

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
    panel.contentView = hosting
    window = panel

    hosting.postsFrameChangedNotifications = true
    // reshape the panel to match SwiftUI's intrinsic size on every layout
    // pass. Y origin is pinned to the menubar, X origin to our anchor, so
    // width grows strictly rightward and the left edge never jumps.
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: hosting, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reshapeToContent() }
    }
    reshapeToContent()
    panel.orderFrontRegardless()
    tint.start()
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
    let h: CGFloat = 24
    let x: CGFloat
    let w: CGFloat
    if hasNotch {
      // 110pt right of center clears the notch cutout on 14/16" MacBooks.
      x = full.origin.x + full.width / 2 + 110
      w = max(60, full.origin.x + full.width - x)
    } else {
      x = full.origin.x
      w = full.width
    }
    let y = full.origin.y + full.height - menubarH + (menubarH - h) / 2
    hosting.centered = !hasNotch
    window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
  }

  func close() {
    window.close()
  }

  /// screen x of the panel's leading edge.
  var originX: CGFloat { window.frame.minX }

}

/// weak holder so SwiftUI can push the hit testable width into the host
/// view after NSHostingView construction.
final class HostingRef: @unchecked Sendable {
  weak var view: NSView?
}

struct BarWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

struct BarWindowRoot: View {
  let screenName: String
  let invalidator: Invalidator
  let tint: WallpaperTint
  let onSwitchWorkspace: (String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void
  let hostingRef: HostingRef
  let centered: Bool

  var body: some View {
    BarView(
      screenName: screenName,
      invalidator: invalidator,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit,
      centered: centered
    )
    .environment(invalidator.generation)
    .environment(tint)
    .onPreferenceChange(BarWidthKey.self) { width in
      MainActor.assumeIsolated {
        (hostingRef.view as? BarHostingView<BarWindowRoot>)?.hitWidth = width
      }
    }
  }
}
