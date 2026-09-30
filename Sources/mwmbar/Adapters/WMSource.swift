import Foundation

@MainActor
protocol WMSource: AnyObject {
  var state: Bar { get }

  /// idempotent; safe to call after connection drops
  func start()

  func switchWorkspace(id: String, monitorId: String)

  func focusWindow(id: String)
}
