protocol WMSource: AnyObject, Sendable {
  /// safe to call multiple times; push a fresh monitor tree on every wm
  /// signal.
  func start(invalidator: Invalidator)
  func switchWorkspace(id: String)
  func refresh()
}
