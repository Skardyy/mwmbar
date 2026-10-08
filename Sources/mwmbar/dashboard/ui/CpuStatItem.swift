import AppKit
import Combine
import SwiftUI

/// menubar cpu% item that opens a dashboard popover. menubar text ticks
/// every 2s; the per process sampler only runs while the popover is open.
@MainActor
final class CpuStatItem: NSObject, NSPopoverDelegate {
  private let item: NSStatusItem
  private var titleTimer: Timer?
  private var prev: HostCpuLoadInfo?

  private let popover = NSPopover()
  private let model = DashboardModel()
  private let store = SystemStore()
  private let caffeine = CaffeineController()
  private let peekPref: PeekPreference
  private let sampler = ProcessSampler()
  private let serviceSampler = ServiceSampler()
  private let serviceStore = ServiceStore()
  private lazy var serviceRefresher = ServiceRefresher(
    store: serviceStore, sampler: serviceSampler)
  private let networkSampler = NetworkSampler()
  private let networkStore = NetworkStore()
  private lazy var networkRefresher = NetworkRefresher(
    store: networkStore, sampler: networkSampler)
  private var sampleTimer: Timer?
  private let sampleQueue = DispatchQueue(label: "mwmbar.cpu.sampler", qos: .userInitiated)
  private var caffeineObserver: AnyCancellable?
  private var lastPercent = "--%"
  /// pre built, uncached between launches but reused forever at runtime so
  /// the status bar refresh does not rebuild NSImage + NSTextAttachment
  /// every 2s tick while amber mode is on.
  private static let caffeineFont = NSFont.monospacedSystemFont(
    ofSize: 12, weight: .semibold)
  private static let caffeineColor = NSColor(
    calibratedRed: 0.98, green: 0.74, blue: 0.28, alpha: 1)
  private static let zzAttachment: NSTextAttachment? = {
    let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [caffeineColor]))
    guard
      let img = NSImage(systemSymbolName: "zzz", accessibilityDescription: "keep awake")?
        .withSymbolConfiguration(cfg)
    else { return nil }
    let a = NSTextAttachment()
    a.image = img
    a.bounds = CGRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
    return a
  }()
  private var lastRendered: (percent: String, caffeine: Bool)?

  init(peekPref: PeekPreference) {
    self.peekPref = peekPref
    // fixed length so title changes do not trigger a menubar wide
    // relayout. 42pt fits "100%" plus the leading zz glyph under a
    // 12pt monospace font without visible trailing padding.
    item = NSStatusBar.system.statusItem(withLength: 42)
    super.init()
    item.length = 42
    item.button?.image = nil
    item.button?.imagePosition = .noImage
    item.button?.alignment = .right
    item.button?.target = self
    item.button?.action = #selector(toggle(_:))
    setTitle("--%")
    popover.behavior = .transient
    popover.delegate = self
    let host = NSHostingController(
      rootView: Dashboard(
        model: model, caffeine: caffeine, peekPref: peekPref, store: store,
        serviceStore: serviceStore,
        networkStore: networkStore,
        onKill: { [weak self] pid, force in
          self?.sampler.kill(pid: pid, force: force)
        },
        onServiceAction: { [weak self] action in
          self?.handleServiceAction(action)
        }
      )
      .environment(store.generation)
      .environment(serviceStore.generation)
      .environment(networkStore.generation))
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
      MainActor.assumeIsolated { self?.tickTitle() }
    }
  }

  private func handleServiceAction(_ action: ServiceAction) {
    let sampler = serviceSampler
    let refresher = serviceRefresher
    DispatchQueue.global(qos: .userInitiated).async {
      switch action {
      case .enable(let label, let path): sampler.enable(label: label, plistPath: path)
      case .disable(let label): sampler.disable(label: label)
      case .start(let label): sampler.start(label: label)
      case .stop(let label): sampler.stop(label: label)
      case .restart(let label): sampler.restart(label: label)
      }
      refresher.kick()
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
    startTabSampler(for: model.tab)
    observeTabChanges()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  private func startTabSampler(for tab: DashboardTab) {
    Log.bar.info("tab start \(tab.rawValue)")
    switch tab {
    case .system:
      sampleOnce()
      startSampling()
    case .services:
      serviceRefresher.start()
    case .network:
      networkRefresher.start()
      networkRefresher.startScan()
    case .settings:
      break
    }
  }

  private func stopAllTabSamplers() {
    Log.bar.info("tab stop all")
    stopSampling()
    serviceRefresher.stop()
    networkRefresher.stop()
    networkRefresher.stopScan()
  }

  // re-arm the observation after each fire; withObservationTracking is
  // one-shot and we need to react to every tab change while the popover
  // stays open.
  private func observeTabChanges() {
    withObservationTracking { [model] in
      _ = model.tab
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.popover.isShown else { return }
        self.stopAllTabSamplers()
        self.startTabSampler(for: self.model.tab)
        self.observeTabChanges()
      }
    }
  }

  func popoverDidClose(_ notification: Notification) {
    Log.bar.info("popover close")
    stopAllTabSamplers()
    networkRefresher.stopScan()
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
      MainActor.assumeIsolated { self?.sampleOnce() }
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
    let busy = currentBusy()
    let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let sampler = self.sampler
    let store = self.store
    sampleQueue.async {
      let procs = sampler.sample()
      let disk = DiskInfo.rootUsage()
      let load = SystemLoad(
        cpuBusy: busy,
        memUsedBytes: HostMemoryInfo.usedBytes(),
        memTotalBytes: HostMemoryInfo.totalBytes(),
        diskUsedBytes: disk.used,
        diskTotalBytes: disk.total,
        coreCount: cores)
      store.commit(SystemSnapshot(load: load, procs: procs))
    }
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

  // repaint menubar label from lastPercent + caffeine state. amber tint
  // and a leading zz glyph appear when caffeine is on.
  private func applyTitle() {
    guard let button = item.button else { return }
    if let last = lastRendered, last.percent == lastPercent, last.caffeine == caffeine.active {
      return
    }
    if caffeine.active, let zz = Self.zzAttachment {
      let s = NSMutableAttributedString()
      s.append(NSAttributedString(attachment: zz))
      s.append(
        NSAttributedString(
          string: lastPercent,
          attributes: [.font: Self.caffeineFont, .foregroundColor: Self.caffeineColor]))
      button.attributedTitle = s
    } else {
      // plain title path is dramatically cheaper than attributedTitle;
      // AppKit does not build an attributed layout for a bare String.
      button.attributedTitle = NSAttributedString()
      button.title = lastPercent
      button.font = Self.caffeineFont
    }
    lastRendered = (lastPercent, caffeine.active)
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

enum DiskInfo {
  // statfs(2) returns block counts for the root volume. f_bavail is what
  // Finder treats as "available" (excludes reserved + apfs purgeable).
  static func rootUsage() -> (used: UInt64, total: UInt64) {
    var buf = statfs()
    guard statfs("/", &buf) == 0 else { return (0, 1) }
    let blockSize = UInt64(buf.f_bsize)
    let total = UInt64(buf.f_blocks) * blockSize
    let free = UInt64(buf.f_bavail) * blockSize
    let used = total > free ? total - free : 0
    return (used, total)
  }
}
