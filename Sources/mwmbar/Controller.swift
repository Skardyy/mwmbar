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
  private lazy var cpu = CpuStatItem(
    peekPref: peekPref,
    onResampleWallpaper: { [weak self] in self?.resampleAllWallpapers() })
  nonisolated(unsafe) private var middleClickMonitor: Any?
  nonisolated(unsafe) private var screenParamsObserver: NSObjectProtocol?

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
    installScreenParamsObserver()
    syncWindows()
    installPerfCounterDump()
  }

  private func resampleAllWallpapers() {
    for bar in windowsByMonitor.values { bar.tint.resample() }
  }

  private func installScreenParamsObserver() {
    screenParamsObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.source?.refresh() }
    }
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
    if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
  }

  private func syncWindows() {
    let snapshot = invalidator.snapshot()
    let liveByName: [String: Monitor] = Dictionary(
      snapshot.monitors.map { ($0.nsScreenName, $0) }, uniquingKeysWith: { a, _ in a })
    for (name, win) in windowsByMonitor where liveByName[name] == nil {
      win.close()
      windowsByMonitor.removeValue(forKey: name)
      peekByMonitor.removeValue(forKey: name)
    }
    for (name, win) in windowsByMonitor {
      if let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
        win.setScreen(screen)
      }
    }
    for monitor in snapshot.monitors where windowsByMonitor[monitor.nsScreenName] == nil {
      let name = monitor.nsScreenName
      let matched = NSScreen.screens.first(where: { $0.localizedName == name })
      guard let screen = matched ?? NSScreen.main else {
        Log.bar.warning("monitor \(name) has no matching NSScreen")
        continue
      }
      let allNames = NSScreen.screens.map { $0.localizedName }.joined(separator: ",")
      Log.bar.debug(
        "bar create name=\(name) matched=\(matched?.localizedName ?? "<fallback main>") fallback=\(matched == nil) nsScreens=[\(allNames)] frame=\(NSStringFromRect(screen.frame))"
      )
      let peek = PeekController(screen: screen, service: peekService, pref: peekPref)
      peekByMonitor[name] = peek
      windowsByMonitor[name] = BarWindow(
        screen: screen, screenName: name,
        invalidator: invalidator,
        onSwitchWorkspace: { [weak self] wsId in
          self?.source?.switchWorkspace(id: wsId)
        },
        onRestoreWindow: { [weak self] id in
          self?.invalidator.restoreWindow(id: id)
        },
        onPeekEnter: { [weak self] ws, pillLocalX in
          guard let self else { return }
          let ids: [CGWindowID] = ws.windows.compactMap { UInt32($0.id) }
          let origin = self.windowsByMonitor[name]?.originX ?? 0
          let screenX = origin + pillLocalX
          Log.bar.debug(
            "peek anchor ws=\(ws.id) local=\(pillLocalX) origin=\(origin) screen=\(screenX)")
          self.peekByMonitor[name]?.enter(
            workspaceId: ws.id, windowIds: ids, pillCenterX: screenX)
        },
        onPeekExit: { [weak self] in
          self?.peekByMonitor[name]?.exit()
        })
    }
    for (name, _) in peekByMonitor where liveByName[name] == nil {
      peekByMonitor.removeValue(forKey: name)
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
