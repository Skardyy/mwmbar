@MainActor
protocol WMSource: AnyObject {
  /// safe to call multiple times. push a fresh monitor tree to `bar.tryUpdate`
  /// on every WM signal; the bar handles diffing and overlaying system state.
  func start(bar: Bar)
  func switchWorkspace(id: String, monitorId: String)
}
