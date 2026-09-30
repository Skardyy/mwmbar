import Foundation

/// sits between the WM source and the observable Bar state. sources submit
/// candidate monitor trees via tryUpdate; the invalidator overrides each
/// window's compositor owned fields (bundleId, name, isHidden) with truth
/// from CompositorTracker and drops windows the compositor has never seen.
/// when the compositor's own state changes, the invalidator reevaluates the
/// last submitted tree so a closed window disappears immediately even if the
/// WM has not caught up yet.
@MainActor
final class Invalidator {
  private let tracker: CompositorTracker
  private let commit: ([Monitor], String?) -> Void
  private var lastMonitors: [Monitor] = []
  private var lastFocus: String?
  private var haveSubmission = false

  init(tracker: CompositorTracker, commit: @escaping ([Monitor], String?) -> Void) {
    self.tracker = tracker
    self.commit = commit
    tracker.onChange = { [weak self] in self?.reevaluate() }
  }

  func tryUpdate(monitors: [Monitor], focusedWindowId: String?) {
    lastMonitors = monitors
    lastFocus = focusedWindowId
    haveSubmission = true
    reevaluate()
  }

  private func reevaluate() {
    guard haveSubmission else { return }
    let filtered = lastMonitors.map { filter($0) }
    let focus = lastFocus.flatMap { tracker.live[$0] != nil ? $0 : nil }
    commit(filtered, focus)
  }

  private func filter(_ monitor: Monitor) -> Monitor {
    var out = monitor
    out.workspaces = monitor.workspaces.map { ws in
      var w = ws
      w.windows = ws.windows.compactMap(overlay)
      return w
    }
    return out
  }

  private func overlay(_ window: Window) -> Window? {
    guard let info = tracker.live[window.id] else {
      Log.bar.debug("drop window \(window.id) (\(window.bundleId)): unknown to compositor")
      return nil
    }
    var out = window
    if let bid = info.bundleId { out.bundleId = bid }
    if let name = info.name { out.name = name }
    out.isHidden = tracker.hidden.contains(window.id)
    return out
  }
}
