import AppKit
import SwiftUI

@MainActor
final class BarController {
  let state = Bar()
  var source: (any WMSource)?
  private var windowsByMonitor: [String: BarWindow] = [:]

  func start() {
    let src = AerospaceSource(state: state)
    source = src
    src.start()
    syncWindows()
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
        })
    }
    // withObservationTracking fires once per change; re-arm to catch the next
    withObservationTracking { [self] in
      _ = state.monitors.map { $0.id }
    } onChange: { [weak self] in
      Task { @MainActor in self?.syncWindows() }
    }
  }
}
