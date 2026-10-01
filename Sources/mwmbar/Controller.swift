import AppKit
import SwiftUI

@MainActor
final class BarController {
  let state = Bar()
  var source: (any WMSource)?
  private var windowsByMonitor: [String: BarWindow] = [:]
  private let cpu = CpuStatItem()
  nonisolated(unsafe) private var middleClickMonitor: Any?

  func start() {
    state.start()
    let src = AerospaceSource()
    source = src
    src.start(bar: state)
    cpu.start()
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
      windowsByMonitor[monitor.id] = BarWindow(
        monitorId: monitor.id, screen: screen, state: state,
        onSwitchWorkspace: { [weak self] wsId, monId in
          self?.source?.switchWorkspace(id: wsId, monitorId: monId)
        },
        onRestoreWindow: { [weak self] id in
          self?.state.restoreWindow(id: id)
        })
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
