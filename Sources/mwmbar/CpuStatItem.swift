import AppKit
import Combine
import SwiftUI

/// standalone NSStatusItem in the system menubar showing overall CPU%.
/// clicking opens a dashboard popover with per process CPU + memory,
/// filter + sort, kill actions, and a caffeine toggle. the menubar text
/// still ticks every 2s from host_statistics; the heavier per process
/// sampler only runs while the popover is visible.
@MainActor
final class CpuStatItem: NSObject, NSPopoverDelegate {
  private let item: NSStatusItem
  private var titleTimer: Timer?
  private var prev: HostCpuLoadInfo?

  private let popover = NSPopover()
  private let model = CpuDashboardModel()
  private let caffeine = CaffeineController()
  private let sampler = ProcessSampler()
  private var sampleTimer: Timer?
  private var caffeineObserver: AnyCancellable?
  private var lastPercent = "--%"

  override init() {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    item.button?.image = nil
    item.button?.imagePosition = .noImage
    item.button?.target = self
    item.button?.action = #selector(toggle(_:))
    setTitle("--%")
    popover.behavior = .transient
    popover.delegate = self
    let host = NSHostingController(
      rootView: CpuDashboard(model: model, caffeine: caffeine) { [weak self] pid, force in
        self?.sampler.kill(pid: pid, force: force)
      })
    popover.contentViewController = host
    // repaint the menubar label whenever caffeine toggles so the tint can
    // reflect it live without waiting for the next 2s cpu tick.
    caffeineObserver = caffeine.$active.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.applyTitle() }
    }
  }

  func start() {
    tickTitle()
    titleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tickTitle() }
    }
  }

  func stop() {
    titleTimer?.invalidate()
    titleTimer = nil
    stopSampling()
  }

  @objc private func toggle(_ sender: Any?) {
    guard let button = item.button else { return }
    if popover.isShown {
      popover.performClose(sender)
      return
    }
    // size against the main screen each open; a 13 inch laptop should not
    // get the same popup as a 32 inch external. clamp bounds live in
    // sizePopoverForScreen so the dashboard never fills a huge display.
    sizePopoverForScreen()
    // seed one sample before showing so the list is populated on first
    // paint. without this the popover appears with an empty table for
    // ~2 s until the first timer fires.
    sampleOnce()
    startSampling()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  func popoverDidClose(_ notification: Notification) {
    stopSampling()
  }

  private func sizePopoverForScreen() {
    guard let frame = NSScreen.main?.visibleFrame else { return }
    let w = max(420, min(640, frame.width * 0.34))
    let h = max(360, min(720, frame.height * 0.55))
    popover.contentSize = CGSize(width: w, height: h)
  }

  private func startSampling() {
    sampleTimer?.invalidate()
    sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sampleOnce() }
    }
  }

  private func stopSampling() {
    sampleTimer?.invalidate()
    sampleTimer = nil
  }

  private func sampleOnce() {
    // per process cpu is per core (one hw thread pinned = 100%) to match
    // Activity Monitor and top. the overall gauge below stays 0 to 100
    // across all cores; mixing the two scales is intentional.
    model.procs = sampler.sample()
    model.load = SystemLoad(
      cpuBusy: currentBusy(),
      memUsedBytes: HostMemoryInfo.usedBytes(),
      memTotalBytes: HostMemoryInfo.totalBytes(),
      coreCount: max(1, ProcessInfo.processInfo.activeProcessorCount))
  }

  private func currentBusy() -> Double {
    guard let sample = HostCpuLoadInfo.read(), let prev else { return 0 }
    let user = sample.user - prev.user
    let system = sample.system - prev.system
    let idle = sample.idle - prev.idle
    let nice = sample.nice - prev.nice
    let total = user + system + idle + nice
    guard total > 0 else { return 0 }
    return Double(user + system + nice) / Double(total) * 100.0
  }

  private func setTitle(_ percent: String) {
    lastPercent = percent
    applyTitle()
  }

  // repaints the menubar label from lastPercent + current caffeine state.
  // when caffeine is on, tint shifts to warm amber (matches the dashboard
  // button) and a small zz glyph slides in before the percent.
  private func applyTitle() {
    guard let button = item.button else { return }
    let color: NSColor =
      caffeine.active
      ? NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.28, alpha: 1)
      : .labelColor
    // full monospaced font (not just digits) so the leading pad space in
    // "%2.0f%%" has the same width as a digit. keeps 7% <-> 10% in place;
    // 100% is naturally wider and shifts, which is fine.
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    let s = NSMutableAttributedString()
    if caffeine.active {
      // SF Symbol tinted via palette config so the menubar actually renders
      // the glyph in the amber tone. the earlier mask-composite extension
      // produced a blank image when passed to NSTextAttachment.
      let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
      let symbol = NSImage(
        systemSymbolName: "zzz", accessibilityDescription: "keep awake")
      if let img = symbol?.withSymbolConfiguration(cfg) {
        let zz = NSTextAttachment()
        zz.image = img
        zz.bounds = CGRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
        s.append(NSAttributedString(attachment: zz))
      }
    }
    s.append(
      NSAttributedString(
        string: lastPercent,
        attributes: [.font: font, .foregroundColor: color]))
    button.attributedTitle = s
  }

  private func tickTitle() {
    guard let sample = HostCpuLoadInfo.read() else {
      setTitle("??")
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
    setTitle(String(format: "%2.0f%%", busy))
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

enum HostMemoryInfo {
  // vm page size is a kernel constant per boot; cache once and skip the
  // mach trap on every refresh.
  private static let pageSize: UInt64 = {
    var p: vm_size_t = 0
    host_page_size(mach_host_self(), &p)
    return UInt64(p)
  }()

  static func totalBytes() -> UInt64 {
    ProcessInfo.processInfo.physicalMemory
  }

  // used = active + wired + compressed. matches Activity Monitor's "Memory
  // Used" number (speculative + file backed cache are considered free).
  static func usedBytes() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard r == KERN_SUCCESS else { return 0 }
    let active = UInt64(stats.active_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize
    return active + wired + compressed
  }
}
