import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = BarController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.start()
  }
}

// bootstrap NSApplication, set accessory policy, and finishLaunching
// before triggering the Accessibility prompt. tccd attributes the
// request to this process's current state; without an activation policy
// and a finished launch the request is silently discarded for launchd
// spawned agents. Screen Recording is prompted lazily on first capture.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

let axOpts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(axOpts)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
