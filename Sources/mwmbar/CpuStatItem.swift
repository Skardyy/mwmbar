import AppKit

/// standalone NSStatusItem in the system menubar showing overall CPU%.
/// samples host_statistics every 2s; delta between samples gives % busy.
@MainActor
final class CpuStatItem {
  private let item: NSStatusItem
  private var timer: Timer?
  private var prev: HostCpuLoadInfo?

  init() {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "CPU --%"
    item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
  }

  func start() {
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard let sample = HostCpuLoadInfo.read() else {
      item.button?.title = "CPU ??"
      return
    }
    defer { prev = sample }
    guard let prev else { return }
    let user = sample.user - prev.user
    let system = sample.system - prev.system
    let idle = sample.idle - prev.idle
    let nice = sample.nice - prev.nice
    let total = user + system + idle + nice
    guard total > 0 else { return }
    let busy = Double(user + system + nice) / Double(total) * 100.0
    item.button?.title = String(format: "CPU %2.0f%%", busy)
  }
}

struct HostCpuLoadInfo {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32

  static func read() -> HostCpuLoadInfo? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return HostCpuLoadInfo(
      user: info.cpu_ticks.0,
      system: info.cpu_ticks.1,
      idle: info.cpu_ticks.2,
      nice: info.cpu_ticks.3)
  }
}
