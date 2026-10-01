import Foundation

/// sits between the WM source and the observable Bar state. sources submit
/// candidate monitor trees via tryUpdate; the invalidator overrides each
/// window's compositor owned fields (bundleId, name, isHidden) with truth
/// from CompositorTracker and drops windows the compositor has never seen.
/// when the compositor's own state changes, the invalidator reevaluates the
/// last submitted tree so a closed window disappears immediately even if the
/// WM has not caught up yet.
///
/// also caches every window's last known (monitorId, workspaceId) so windows
/// the WM stops reporting (aerospace drops minimized windows from
/// list-windows --all after a while) can be reinjected as hidden entries as
/// long as the compositor still says they exist.
@MainActor
final class Invalidator {
  private let tracker: CompositorTracker
  private let commit: ([Monitor], String?) -> Void
  private var lastMonitors: [Monitor] = []
  private var haveSubmission = false
  private var placement: [String: (monitorId: String, workspaceId: String)] = [:]

  init(tracker: CompositorTracker, commit: @escaping ([Monitor], String?) -> Void) {
    self.tracker = tracker
    self.commit = commit
    tracker.onChange = { [weak self] in self?.reevaluate() }
    tracker.onFocusChange = { [weak self] in self?.reevaluate() }
  }

  func tryUpdate(monitors: [Monitor]) {
    lastMonitors = monitors
    haveSubmission = true
    updatePlacement(from: monitors)
    reevaluate()
  }

  private func updatePlacement(from monitors: [Monitor]) {
    for monitor in monitors {
      for ws in monitor.workspaces {
        for w in ws.windows {
          placement[w.id] = (monitor.id, ws.id)
        }
      }
    }
  }

  private func reevaluate() {
    guard haveSubmission else { return }
    var reinjectByWs: [String: [Window]] = [:]
    let known = Set(lastMonitors.flatMap { $0.workspaces.flatMap { $0.windows.map(\.id) } })
    for (id, info) in tracker.live where !known.contains(id) {
      guard let place = placement[id] else { continue }
      let name = info.name ?? ""
      let bid = info.bundleId ?? ""
      let win = Window(id: id, bundleId: bid, name: name, isHidden: tracker.hidden.contains(id))
      reinjectByWs["\(place.monitorId)/\(place.workspaceId)", default: []].append(win)
    }

    let filtered = lastMonitors.map { monitor in
      var out = monitor
      out.workspaces = monitor.workspaces.map { ws in
        var w = ws
        w.windows = ws.windows.compactMap(overlay)
        if let extras = reinjectByWs["\(monitor.id)/\(ws.id)"] {
          w.windows.append(contentsOf: extras)
        }
        return w
      }
      return out
    }
    let focus = tracker.focusedWindowId.flatMap { tracker.live[$0] != nil ? $0 : nil }
    commit(filtered, focus)
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
