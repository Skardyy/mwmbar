import AppKit
import SwiftUI

@MainActor
final class BarController {
  let invalidator = Invalidator()
  var source: (any WMSource)?
  private var windowsByMonitor: [String: BarWindow] = [:]
  private var peekByMonitor: [String: PeekController] = [:]
  private let peekService = PeekService()
  private let peekPref = PeekPreference()
  private lazy var cpu = CpuStatItem(peekPref: peekPref)
  nonisolated(unsafe) private var middleClickMonitor: Any?

  private static func makeSource() -> any WMSource {
    AerospaceSource()
  }

  func start() {
    invalidator.start()
    let src: any WMSource = Self.makeSource()
    source = src
    src.start(invalidator: invalidator)
    cpu.start()
    invalidator.onLifecycleChange = { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.peekService.invalidateAll()
        for peek in self.peekByMonitor.values { peek.refreshIfShown() }
      }
    }
    installMiddleClickMonitor()
    syncWindows()
    installPerfCounterDump()
  }

  // periodic counter flush so a reader can see throughput buckets without
  // scrolling through every per event span log. only runs when MWMBAR_PERF
  // is set (PerfTrace guards internally).
  private func installPerfCounterDump() {
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
      MainActor.assumeIsolated { PerfTrace.dumpCounters() }
    }
  }

  /// middle click on a hovered icon closes its window via the compositor.
  private func installMiddleClickMonitor() {
    middleClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .otherMouseDown
    ) { [weak self] event in
      guard event.buttonNumber == 2 else { return event }
      guard let id = IconHoverRegistry.shared.hoveredWindowId else { return event }
      self?.invalidator.closeWindow(id: id)
      return nil
    }
  }

  deinit {
    if let middleClickMonitor { NSEvent.removeMonitor(middleClickMonitor) }
  }

  private func syncWindows() {
    let snapshot = invalidator.snapshot()
    let live = Set(snapshot.monitors.map { $0.id })
    for (id, win) in windowsByMonitor where !live.contains(id) {
      win.close()
      windowsByMonitor.removeValue(forKey: id)
    }
    for monitor in snapshot.monitors where windowsByMonitor[monitor.id] == nil {
      guard
        let screen = NSScreen.screens.first(where: { $0.localizedName == monitor.nsScreenName })
          ?? NSScreen.main
      else {
        Log.bar.warning("monitor \(monitor.id) has no matching NSScreen")
        continue
      }
      let peek = PeekController(screen: screen, service: peekService, pref: peekPref)
      peekByMonitor[monitor.id] = peek
      let monId = monitor.id
      windowsByMonitor[monitor.id] = BarWindow(
        monitorId: monitor.id, screen: screen, invalidator: invalidator,
        onSwitchWorkspace: { [weak self] wsId, monId in
          self?.source?.switchWorkspace(id: wsId, monitorId: monId)
        },
        onRestoreWindow: { [weak self] id in
          self?.invalidator.restoreWindow(id: id)
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
    // observe generation tick to re run after each commit; withObservation
    // Tracking fires once so resubscribe each call.
    withObservationTracking { [invalidator] in
      _ = invalidator.generation.tick
    } onChange: { [weak self] in
      Task { @MainActor in self?.syncWindows() }
    }
  }
}
