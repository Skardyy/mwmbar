import AppKit
import SwiftUI

@main
struct MwmbarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    Settings { EmptyView() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = BarController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    controller.start()
  }
}
