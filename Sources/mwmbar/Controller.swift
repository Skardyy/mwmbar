import AppKit
import SwiftUI

@MainActor
final class BarController {
  let state = Bar()
  var source: (any WMSource)?
  private var windowsByMonitor: [String: BarWindow] = [:]
  private var peekByMonitor: [String: PeekController] = [:]
  private let peekService = PeekService()
  private let cpu = CpuStatItem()
  nonisolated(unsafe) private var middleClickMonitor: Any?

  func start() {
    state.start()
    let src = AerospaceSource()
    source = src
    src.start(bar: state)
    cpu.start()
    peekService.ensurePermission()
    state.onLifecycleChange = { [weak self] in
      guard let self else { return }
      self.peekService.invalidateAll()
      for peek in self.peekByMonitor.values { peek.refreshIfShown() }
    }
    installMiddleClickMonitor()
    syncWindows()
  }

  /// middle click on a hovered icon closes its window via the compositor.
  private func installMiddleClickMonitor() {
    middleClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .otherMouseDown
    ) { [weak self] event in
      guard event.buttonNumber == 2 else { return event }
      guard let id = IconHoverRegistry.shared.hoveredWindowId else { return event }
      self?.state.closeWindow(id: id)
      return nil
    }
  }

  deinit {
    if let middleClickMonitor { NSEvent.removeMonitor(middleClickMonitor) }
  }

  private func syncWindows() {
    let live = Set(state.monitors.map { $0.id })
    for (id, win) in windowsByMonitor where !live.contains(id) {
      win.close()
      windowsByMonitor.removeValue(forKey: id)
    }
    for monitor in state.monitors where windowsByMonitor[monitor.id] == nil {
      guard
        let screen = NSScreen.screens.first(where: { $0.localizedName == monitor.nsScreenName })
          ?? NSScreen.main
      else {
        Log.bar.warning("monitor \(monitor.id) has no matching NSScreen")
        continue
      }
      let peek = PeekController(screen: screen, service: peekService)
      peekByMonitor[monitor.id] = peek
      let monId = monitor.id
      windowsByMonitor[monitor.id] = BarWindow(
        monitorId: monitor.id, screen: screen, state: state,
        onSwitchWorkspace: { [weak self] wsId, monId in
          self?.source?.switchWorkspace(id: wsId, monitorId: monId)
        },
        onRestoreWindow: { [weak self] id in
          self?.state.restoreWindow(id: id)
        },
        onPeekEnter: { [weak self] ws, pillLocalX in
          guard let self else { return }
          let ids: [CGWindowID] = ws.windows.compactMap { UInt32($0.id) }
          let origin = self.windowsByMonitor[monId]?.originX ?? 0
          let screenX = origin + pillLocalX
          Log.bar.debug(
            "peek anchor ws=\(ws.id) local=\(pillLocalX) origin=\(origin) screen=\(screenX)")
          self.peekByMonitor[monId]?.enter(
            workspaceId: ws.id, windowIds: ids, pillCenterX: screenX)
        },
        onPeekExit: { [weak self] in
          self?.peekByMonitor[monId]?.exit()
        })
    }
    for (id, _) in peekByMonitor where !live.contains(id) {
      peekByMonitor.removeValue(forKey: id)
    }
    // withObservationTracking fires onChange exactly once; recurse into
    // syncWindows from the handler to resubscribe for the next change.
    withObservationTracking { [self] in
      _ = state.monitors.map { $0.id }
    } onChange: { [weak self] in
      Task { @MainActor in self?.syncWindows() }
    }
  }
}
