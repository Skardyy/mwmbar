import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = BarController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.start()
  }
}

// accessory policy is set before run() so the status item is reachable
// before any wm backend starts. the Accessibility prompt is deferred to
// the window tracking backend, so a user running without a wm backend is
// never prompted.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
