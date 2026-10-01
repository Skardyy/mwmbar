import Foundation

@MainActor
final class AerospaceSource: WMSource {
  private weak var bar: Bar?
  // two sockets: the events socket is parked in `subscribe --all` and cannot serve requests,
  // so cmd needs its own connection for list-monitors / list-workspaces / workspace switches.
  private let cmd = AerospaceSocket()
  private let events = AerospaceSocket()

  func start(bar: Bar) {
    self.bar = bar
    cmd.connect { [weak self] err in
      if let err {
        Log.source.warning("aerospace cmd socket connect failed: \(String(describing: err))")
        return
      }
      Task { @MainActor in await self?.refresh() }
    }
    events.connect { [weak self] err in
      if let err {
        Log.source.warning("aerospace events socket connect failed: \(String(describing: err))")
        return
      }
      guard let self else { return }
      self.events.onFrame = { [weak self] payload in
        do {
          let event = try JSONDecoder().decode(AerospaceServerEvent.self, from: payload)
          Log.source.debug("event \(event.event)")
        } catch {
          let prefix = String(data: payload.prefix(120), encoding: .utf8) ?? "<bin>"
          Log.source.error(
            "aerospace event decode failed: \(error). prefix=\(prefix)")
        }
        Task { @MainActor in await self?.refresh() }
      }
      self.events.send(args: ["subscribe", "--all"]) { r in
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
    do {
      let monitors = try await monitorsF
      let workspaces = try await workspacesF
      let windows = try await windowsF
      apply(monitors: monitors, workspaces: workspaces, windows: windows)
    } catch {
      Log.source.warning("aerospace refresh aborted: \(String(describing: error))")
    }
  }

  private func fetch<T: Decodable & Sendable>(
    _ type: [T].Type, args: [String]
  ) async throws -> [T] {
    let resp = try await cmd.send(args: args)
    guard resp.exitCode == 0 else {
      throw AerospaceSocketError(
        message: "non-zero exit \(resp.exitCode) stderr=\(resp.stderr)")
    }
    guard let data = resp.stdout.data(using: .utf8) else {
      throw AerospaceSocketError(message: "stdout not utf8")
    }
    return try JSONDecoder().decode([T].self, from: data)
  }

  private func apply(
    monitors: [AerospaceMonitorRow],
    workspaces: [AerospaceWorkspaceRow],
    windows: [AerospaceWindowRow]
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
      let workspace = Workspace(id: ws.id, windows: [])
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

    let finalMonitors = monitorOrder.compactMap { monitorById[$0] }
    for m in finalMonitors {
      let ids = m.workspaces.map { "\($0.id)(\($0.windows.count))" }.joined(separator: ",")
      Log.source.debug(
        "monitor \(m.id) focused=\(m.focusedWorkspaceId ?? "nil") ws=[\(ids)]")
    }
    bar?.tryUpdate(monitors: finalMonitors)
  }
}
