import AppKit
import ApplicationServices

/// trigger the Accessibility prompt while the process is still fresh to
/// tccd (before NSApplication initialises its own event loop). calling
/// this later, from applicationDidFinishLaunching, is silently swallowed
/// when the process was spawned by launchd. Screen Recording is prompted
/// lazily on first capture so a denied grant does not block the bar.
func ensureAccessibility() {
  let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
  _ = AXIsProcessTrustedWithOptions(opts)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = BarController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    controller.start()
  }
}

ensureAccessibility()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
