import AppKit
import SwiftUI

/// hosting view that only accepts mouse events inside the bar BG region.
/// BarView sends the current BG width via a preference. the panel's
/// ignoresMouseEvents is toggled by a global mouse monitor (see BarWindow)
/// since once the panel is ignoring events it can no longer detect the
/// mouse coming back on its own.
final class BarHostingView<Content: View>: NSHostingView<Content> {
  var hitWidth: CGFloat = 0

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard point.x >= 0 && point.x <= hitWidth else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
final class BarWindow {
  private let window: NSPanel
  private let hosting: BarHostingView<BarWindowRoot>
  private var screen: NSScreen
  private let tint: WallpaperTint
  nonisolated(unsafe) private var frameObserver: NSObjectProtocol?
  nonisolated(unsafe) private var mouseMonitor: Any?
  nonisolated(unsafe) private var globalMouseMonitor: Any?

  init(
    monitorId: String, screen: NSScreen, state: Bar,
    onSwitchWorkspace: @escaping (String, String) -> Void,
    onRestoreWindow: @escaping (String) -> Void,
    onPeekEnter: @escaping (Workspace, CGFloat) -> Void,
    onPeekExit: @escaping () -> Void
  ) {
    let hostingRef = HostingRef()
    let displayId =
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
      .uint32Value ?? CGMainDisplayID()
    let tint = WallpaperTint(display: displayId)
    self.tint = tint
    let root = BarWindowRoot(
      monitorId: monitorId,
      state: state,
      tint: tint,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit,
      hostingRef: hostingRef)
    hosting = BarHostingView(rootView: root)
    hostingRef.view = hosting
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
    panel.contentView = hosting
    // start ignoring; a global mouse monitor flips this off whenever the
    // cursor is actually over the bar BG region.
    panel.ignoresMouseEvents = true
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
    installMouseMonitor()
    tint.start()
  }

  deinit {
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
    }
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
  }

  // keep `ignoresMouseEvents` in sync with the cursor position: on when it
  // sits inside the live bar BG, off everywhere else. runs on every mouse
  // move system wide (cheap) because once the panel is ignoring events it
  // cannot track its own cursor returning.
  private func installMouseMonitor() {
    let apply: @MainActor (NSEvent) -> Void = { [weak self] _ in
      guard let self else { return }
      self.updateMousePassthrough()
    }
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
      MainActor.assumeIsolated { apply(event) }
    }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
      MainActor.assumeIsolated { apply(event) }
      return event
    }
  }

  private func updateMousePassthrough() {
    let mouse = NSEvent.mouseLocation
    let frame = window.frame
    let hit = hosting.hitWidth
    // active region: panel's leading edge up to the current BG width, full
    // panel height. mouse anywhere else = pass through.
    let active = NSRect(x: frame.minX, y: frame.minY, width: hit, height: frame.height)
    let inside = active.contains(mouse)
    if window.ignoresMouseEvents != !inside {
      window.ignoresMouseEvents = !inside
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
    if hasNotch {
      // 110pt right of center clears the notch cutout on 14/16" MacBooks.
      x = full.origin.x + full.width / 2 + 110
    } else {
      x = full.origin.x + 110
    }
    // panel spans from its anchor to the screen's right edge. SwiftUI content
    // uses .frame(maxWidth: .infinity, alignment: .leading) so the pills live
    // on the left and the dead space to the right stays empty.
    let w = max(60, full.origin.x + full.width - x)
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

/// weak back channel for BarView to push the current hit testable width
/// into the hosting view. NSHostingView is created before SwiftUI emits any
/// state, so the ref gets filled in during BarWindow init right after.
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
  let monitorId: String
  let state: Bar
  let tint: WallpaperTint
  let onSwitchWorkspace: (String, String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void
  let hostingRef: HostingRef

  var body: some View {
    BarView(
      monitorId: monitorId,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit
    )
    .environment(state)
    .environment(tint)
    .onPreferenceChange(BarWidthKey.self) { width in
      MainActor.assumeIsolated {
        (hostingRef.view as? BarHostingView<BarWindowRoot>)?.hitWidth = width
      }
    }
  }
}
