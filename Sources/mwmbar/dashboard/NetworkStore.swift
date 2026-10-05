import Atomics
import Foundation
import Observation

struct LanDevice: Identifiable, Hashable, Sendable {
  let ip: String
  let mac: String
  let hostname: String?
  var id: String { ip }
}

enum LinkKind: Sendable {
  case wifi
  case wired
  case vpn
  case unknown

  var icon: String {
    switch self {
    case .wifi: return "wifi"
    case .wired: return "cable.connector"
    case .vpn: return "lock.shield.fill"
    case .unknown: return "network.slash"
    }
  }
}

struct NetworkSnapshot: Sendable {
  var linkKind: LinkKind = .unknown
  var linkName: String?
  var signalBars: Int?
  var localIP: String?
  var publicIP: String?
  var vpnActive: Bool = false
  var lan: [LanDevice] = []
  var lastScanned: Date?
  var scanning: Bool = false
}

@MainActor
@Observable
final class NetworkGeneration {
  var tick: UInt64 = 0
}

private final class NetworkSnapshotBox: @unchecked Sendable {
  let value: NetworkSnapshot
  init(_ value: NetworkSnapshot) { self.value = value }
}

final class NetworkStore: @unchecked Sendable {
  let generation: NetworkGeneration
  private let snapshotPtr: ManagedAtomic<UInt>

  @MainActor init() {
    self.generation = NetworkGeneration()
    let box = NetworkSnapshotBox(NetworkSnapshot())
    let raw = Unmanaged.passRetained(box).toOpaque()
    self.snapshotPtr = ManagedAtomic<UInt>(UInt(bitPattern: raw))
  }

  deinit {
    let raw = snapshotPtr.load(ordering: .relaxed)
    if let ptr = UnsafeRawPointer(bitPattern: raw) {
      Unmanaged<NetworkSnapshotBox>.fromOpaque(ptr).release()
    }
  }

  @MainActor func snapshot() -> NetworkSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<NetworkSnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }

  func commit(_ snap: NetworkSnapshot) {
    let newBox = NetworkSnapshotBox(snap)
    let newRaw = Unmanaged.passRetained(newBox).toOpaque()
    let oldRawInt = snapshotPtr.exchange(
      UInt(bitPattern: newRaw), ordering: .acquiringAndReleasing)
    let gen = generation
    Task { @MainActor in
      if let oldPtr = UnsafeRawPointer(bitPattern: oldRawInt) {
        Unmanaged<NetworkSnapshotBox>.fromOpaque(oldPtr).release()
      }
      gen.tick &+= 1
    }
  }

  /// mutate the snapshot without re-sampling the whole thing. caller does a
  /// read / modify / commit under a serial queue so no two writers race.
  func patch(_ apply: (inout NetworkSnapshot) -> Void) {
    var snap = currentForWriter()
    apply(&snap)
    commit(snap)
  }

  private func currentForWriter() -> NetworkSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<NetworkSnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }
}

/// drives NetworkStore from a background queue. summary (local/public/vpn/ssid)
/// refreshes periodically; LAN scan is kick-only to avoid constant arp traffic.
final class NetworkRefresher: @unchecked Sendable {
  private let store: NetworkStore
  private let sampler: NetworkSampler
  private let queue = DispatchQueue(label: "mwmbar.network", qos: .utility)
  private let summaryInterval: TimeInterval

  init(store: NetworkStore, sampler: NetworkSampler, summaryInterval: TimeInterval = 15.0) {
    self.store = store
    self.sampler = sampler
    self.summaryInterval = summaryInterval
  }

  private var summaryTimer: DispatchSourceTimer?

  func start() {
    stop()
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: summaryInterval)
    t.setEventHandler { [weak self] in self?.refreshSummary() }
    t.resume()
    summaryTimer = t
  }

  func stop() {
    summaryTimer?.cancel()
    summaryTimer = nil
  }

  private var listener: ArpListener?
  private var coordinator: ScanCoordinator?

  func startScan() {
    stopScan()
    store.patch { snap in
      snap.scanning = true
      snap.lan = []
    }
    let coord = ScanCoordinator(store: store)
    let arp = ArpListener()
    arp.start(
      interface: "en0",
      onDevice: { ip, mac in coord.onArp(ip: ip, mac: mac) },
      onError: { _ in })
    listener = arp
    coordinator = coord
  }

  func stopScan() {
    listener?.stop()
    listener = nil
    coordinator = nil
    store.patch { snap in
      snap.scanning = false
      snap.lastScanned = Date()
    }
  }

  private func refreshSummary() {
    let s = sampler.summary()
    store.patch { snap in
      snap.linkKind = s.linkKind
      snap.linkName = s.linkName
      snap.signalBars = s.signalBars
      snap.localIP = s.localIP
      snap.publicIP = s.publicIP
      snap.vpnActive = s.vpnActive
    }
  }
}

/// merges live scan results into the store. serial queue so mdns +
/// ping-sweep callbacks never race on the same lan dictionary.
private final class ScanCoordinator: @unchecked Sendable {
  private let store: NetworkStore
  private let serial = DispatchQueue(label: "mwmbar.network.coord")
  private var byIp: [String: LanDevice] = [:]

  init(store: NetworkStore) {
    self.store = store
  }

  func onArp(ip: String, mac: String) {
    serial.async { [self] in
      if let existing = byIp[ip], existing.mac == mac { return }
      let host = byIp[ip]?.hostname ?? NetworkSampler.reverseDns(ip)
      byIp[ip] = LanDevice(ip: ip, mac: mac, hostname: host)
      publish()
    }
  }

  private func publish() {
    let snapshot = byIp.values.sorted { ipOrder($0.ip) < ipOrder($1.ip) }
    store.patch { snap in snap.lan = snapshot }
  }

  private func ipOrder(_ ip: String) -> UInt32 {
    let parts = ip.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4 else { return 0 }
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
  }
}
