import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = BarController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.start()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
