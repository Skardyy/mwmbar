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
  private let wmPref = WMPreference()
  private lazy var cpu = CpuStatItem(
    peekPref: peekPref,
    wmPref: wmPref,
    onResampleWallpaper: { [weak self] in self?.resampleAllWallpapers() },
    onSwitchWm: { [weak self] kind in self?.switchKind(kind) })
  nonisolated(unsafe) private var middleClickMonitor: Any?
  nonisolated(unsafe) private var screenParamsObserver: NSObjectProtocol?
  private var wmActive = false

  func start() {
    cpu.start()
    bringUpWM(kind: wmPref.kind)
  }

  func switchKind(_ kind: WMKind) {
    if kind == wmPref.kind && wmActive { return }
    Log.bar.info("switchKind \(kind.rawValue)")
    tearDownWM()
    wmPref.kind = kind
    bringUpWM(kind: kind)
  }

  private func bringUpWM(kind: WMKind) {
    if wmActive { return }
    Log.bar.info("bringUpWM \(kind.rawValue)")
    switch kind {
    case .none:
      wmActive = true
      return
    case .aerospace:
      invalidator.start()
      let src: any WMSource = AerospaceSource()
      source = src
      src.start(invalidator: invalidator)
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
      wmActive = true
    }
  }

  private func tearDownWM() {
    if !wmActive { return }
    Log.bar.info("tearDownWM")
    for (name, win) in windowsByMonitor {
      win.close()
      windowsByMonitor.removeValue(forKey: name)
    }
    peekByMonitor.removeAll()
    peekService.invalidateAll()
    if let mon = middleClickMonitor { NSEvent.removeMonitor(mon) }
    middleClickMonitor = nil
    if let obs = screenParamsObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    screenParamsObserver = nil
    source?.stop()
    source = nil
    invalidator.stop()
    wmActive = false
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

    // remove any bars on monitors that no longer exists
    let liveByName: [String: Monitor] = Dictionary(
      snapshot.monitors.map { ($0.nsScreenName, $0) }, uniquingKeysWith: { a, _ in a })
    for (name, win) in windowsByMonitor where liveByName[name] == nil {
      win.close()
      windowsByMonitor.removeValue(forKey: name)
      peekByMonitor.removeValue(forKey: name)
    }

    // re point the live bars into their screens
    for (name, win) in windowsByMonitor {
      if let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
        win.setScreen(screen)
      }
    }

    for monitor in snapshot.monitors where windowsByMonitor[monitor.nsScreenName] == nil {
      // match monitor name to NSScreen
      let name = monitor.nsScreenName
      let matched = NSScreen.screens.first(where: { $0.localizedName == name })
      guard let screen = matched ?? NSScreen.main else {
        Log.bar.warning("monitor \(name) has no matching NSScreen")
        continue
      }
      Log.bar.debug(
        "bar create name=\(name) matched=\(matched?.localizedName ?? "<fallback main>") "
          + "fallback=\(matched == nil) "
          + "nsScreens=[\(NSScreen.screens.map { $0.localizedName }.joined(separator: ","))] "
          + "frame=\(NSStringFromRect(screen.frame))"
      )

      // peek
      let peek = PeekController(screen: screen, service: peekService, pref: peekPref)
      peekByMonitor[name] = peek

      // create bars
      windowsByMonitor[name] = BarWindow(
        screen: screen, screenName: name,
        invalidator: invalidator,
        onSwitchWorkspace: { [weak self] wsId in
          self?.source?.switchWorkspace(id: wsId)
        },
        onRestoreWindow: { [weak self] id in
          self?.invalidator.unhideWindow(id: id)
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

    // rerender on invalidator tick
    withObservationTracking { [invalidator] in
      _ = invalidator.generation.tick
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.wmActive else { return }
        self.syncWindows()
      }
    }
  }
}
