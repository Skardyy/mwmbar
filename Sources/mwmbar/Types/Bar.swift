import Foundation
import Observation

@Observable
@MainActor
final class Bar {
  var monitors: [Monitor] = []
  var focusedWindowId: String?

  func setMonitor(_ monitor: Monitor) {
    if let i = monitors.firstIndex(where: { $0.id == monitor.id }) {
      monitors[i] = monitor
    } else {
      monitors.append(monitor)
    }
  }

  func removeMonitor(id: String) {
    monitors.removeAll { $0.id == id }
  }

  func setAll(monitors: [Monitor], focusedWindowId: String?) {
    self.monitors = monitors
    self.focusedWindowId = focusedWindowId
  }
}
