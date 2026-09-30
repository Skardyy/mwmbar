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
      // socket callback fires on the socket's serial queue; hop to MainActor
      // before touching bar state.
      Task { @MainActor in await self?.refresh() }
    }
    events.connect { [weak self] err in
      if let err {
        Log.source.warning("aerospace events socket connect failed: \(String(describing: err))")
        return
      }
      guard let self else { return }
      self.events.onFrame = { [weak self] _ in
        Task { @MainActor in await self?.refresh() }
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

  private func refresh() async {
    async let monitorsF = fetch(
      [AerospaceMonitorRow].self,
      args: [
        "list-monitors", "--json",
        "--format", "%{monitor-id}%{monitor-name}",
      ])
    async let workspacesF = fetch(
      [AerospaceWorkspaceRow].self,
      args: [
        "list-workspaces", "--all", "--json",
        "--format",
        "%{workspace}%{monitor-id}%{workspace-is-visible}%{workspace-root-container-layout}",
      ])
    async let windowsF = fetch(
      [AerospaceWindowRow].self,
      args: [
        "list-windows", "--all", "--json",
        "--format", "%{window-id}%{app-name}%{app-bundle-id}%{workspace}%{monitor-id}",
      ])
    async let focusedF = fetch(
      [AerospaceFocusedRow].self,
      args: [
        "list-windows", "--focused", "--json",
        "--format", "%{window-id}",
      ])
    let monitors = await monitorsF
    let workspaces = await workspacesF
    let windows = await windowsF
    let focused = await focusedF
    apply(monitors: monitors, workspaces: workspaces, windows: windows, focused: focused)
  }

  private func fetch<T: Decodable & Sendable>(_ type: [T].Type, args: [String]) async -> [T] {
    do {
      let resp = try await cmd.send(args: args)
      guard resp.exitCode == 0 else {
        Log.source.warning("aerospace non-zero exit \(resp.exitCode) stderr=\(resp.stderr)")
        return []
      }
      guard let data = resp.stdout.data(using: .utf8) else {
        Log.source.warning("aerospace stdout not utf8")
        return []
      }
      return try JSONDecoder().decode([T].self, from: data)
    } catch {
      Log.source.warning("aerospace fetch failed: \(String(describing: error))")
      return []
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
        id: ws.id,
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
        Window(id: String(w.id), bundleId: w.bundleId, name: w.appName))
      monitorById[key.monitorId] = monitor
    }

    let focusedWindowId = focused.first.map { String($0.id) }
    state.setAll(
      monitors: monitorOrder.compactMap { monitorById[$0] },
      focusedWindowId: focusedWindowId)
  }
}
