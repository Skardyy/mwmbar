import Foundation

@MainActor
final class AerospaceSource: WMSource {
  let state: Bar

  private let cmd = AerospaceSocket()
  private let events = AerospaceSocket()

  init(state: Bar) {
    self.state = state
  }

  func start() {
    cmd.connect { [weak self] err in
      if let err {
        Log.source.warning("aerospace cmd socket connect failed: \(String(describing: err))")
        return
      }
      self?.refresh()
    }
    events.connect { [weak self] err in
      if let err {
        Log.source.warning("aerospace events socket connect failed: \(String(describing: err))")
        return
      }
      guard let self else { return }
      self.events.onFrame = { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      }
      self.events.send(args: [
        "subscribe", "focus-changed",
        "focused-workspace-changed",
        "focused-monitor-changed",
        "window-detected",
      ]) { r in
        if case .failure(let e) = r {
          Log.source.warning("aerospace subscribe failed: \(String(describing: e))")
        }
      }
    }
  }

  func switchWorkspace(id: String, monitorId: String) {
    cmd.send(args: ["workspace", id]) { r in
      if case .failure(let e) = r {
        Log.source.warning("aerospace workspace \(id) failed: \(String(describing: e))")
      }
    }
  }

  func focusWindow(id: String) {
    cmd.send(args: ["focus", "--window-id", id]) { r in
      if case .failure(let e) = r {
        Log.source.warning("aerospace focus \(id) failed: \(String(describing: e))")
      }
    }
  }

  private func refresh() {
    let group = DispatchGroup()
    var monitors: [AerospaceMonitorRow] = []
    var workspaces: [AerospaceWorkspaceRow] = []
    var windows: [AerospaceWindowRow] = []
    var focused: [AerospaceFocusedRow] = []

    group.enter()
    cmd.send(args: [
      "list-monitors", "--json",
      "--format", "%{monitor-id}%{monitor-name}",
    ]) { r in
      monitors = Self.decode(r)
      group.leave()
    }
    group.enter()
    cmd.send(args: [
      "list-workspaces", "--all", "--json",
      "--format",
      "%{workspace}%{monitor-id}%{workspace-is-visible}%{workspace-root-container-layout}",
    ]) { r in
      workspaces = Self.decode(r)
      group.leave()
    }
    group.enter()
    cmd.send(args: [
      "list-windows", "--all", "--json",
      "--format", "%{window-id}%{app-name}%{app-bundle-id}%{workspace}%{monitor-id}",
    ]) { r in
      windows = Self.decode(r)
      group.leave()
    }
    group.enter()
    cmd.send(args: [
      "list-windows", "--focused", "--json",
      "--format", "%{window-id}",
    ]) { r in
      focused = Self.decode(r)
      group.leave()
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.apply(
        monitors: monitors, workspaces: workspaces,
        windows: windows, focused: focused)
    }
  }

  private static func decode<T: Decodable>(_ r: Result<AerospaceResponse, Error>) -> [T] {
    switch r {
    case .failure(let e):
      Log.source.warning("aerospace request failed: \(String(describing: e))")
      return []
    case .success(let resp):
      guard resp.exitCode == 0 else {
        Log.source.warning("aerospace non-zero exit \(resp.exitCode) stderr=\(resp.stderr)")
        return []
      }
      guard let data = resp.stdout.data(using: .utf8) else {
        Log.source.warning("aerospace stdout not utf8")
        return []
      }
      do {
        return try JSONDecoder().decode([T].self, from: data)
      } catch {
        Log.source.warning("aerospace decode failed: \(String(describing: error))")
        return []
      }
    }
  }

  private func apply(
    monitors: [AerospaceMonitorRow],
    workspaces: [AerospaceWorkspaceRow],
    windows: [AerospaceWindowRow],
    focused: [AerospaceFocusedRow]
  ) {
    var monitorById: [Int: Monitor] = [:]
    var monitorOrder: [Int] = []
    for m in monitors {
      monitorById[m.id] = Monitor(
        id: String(m.id), nsScreenName: m.name,
        workspaces: [], focusedWorkspaceId: nil)
      monitorOrder.append(m.id)
    }

    var workspaceKey: [String: (monitorId: Int, wsIndex: Int)] = [:]
    for ws in workspaces {
      let workspace = Workspace(
        id: ws.id, isVisible: ws.isVisible,
        preserveOrder: ws.rootLayout.contains("accordion"),
        windows: [])
      guard var monitor = monitorById[ws.monitorId] else {
        Log.source.warning("workspace \(ws.id) references unknown monitor \(ws.monitorId)")
        continue
      }
      monitor.workspaces.append(workspace)
      if ws.isVisible { monitor.focusedWorkspaceId = ws.id }
      monitorById[ws.monitorId] = monitor
      workspaceKey[ws.id] = (ws.monitorId, monitor.workspaces.count - 1)
    }

    for w in windows {
      guard let key = workspaceKey[w.workspace] else {
        Log.source.warning("window \(w.id) references unknown workspace \(w.workspace)")
        continue
      }
      guard var monitor = monitorById[key.monitorId] else {
        Log.source.warning("window \(w.id) references unknown monitor \(key.monitorId)")
        continue
      }
      monitor.workspaces[key.wsIndex].windows.append(
        Window(id: String(w.id), bundleId: w.bundleId, name: w.appName, isHidden: false))
      monitorById[key.monitorId] = monitor
    }

    let focusedWindowId = focused.first.map { String($0.id) }
    state.setAll(
      monitors: monitorOrder.compactMap { monitorById[$0] },
      focusedWindowId: focusedWindowId)
  }
}
