import Foundation

/// merges a candidate monitor tree with the live CompositorTracker view before
/// handing it to `commit`. for every window in the submitted tree it overlays
/// bundleId, name, and isHidden from the tracker and drops windows the tracker
/// does not know. reevaluates on tracker change so UI reflects window close
/// and focus events without waiting for another submission.
///
/// remembers the last (monitorId, workspaceId) seen for each window id and
/// reinjects tracker windows that fall out of the submitted tree at their
/// remembered slot, as hidden entries when the tracker marks them hidden.
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
    let span = PerfTrace.begin("invalidator.reevaluate")
    defer { PerfTrace.end(span) }
    PerfTrace.incr("invalidator.reevaluate")
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
