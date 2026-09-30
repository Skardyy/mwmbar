@MainActor
protocol WMSource: AnyObject {
  /// idempotent. bar handles compositor tracking and diffing internally;
  /// sources only need to call bar.tryUpdate on any signal.
  func start(bar: Bar)
  func switchWorkspace(id: String, monitorId: String)
}
