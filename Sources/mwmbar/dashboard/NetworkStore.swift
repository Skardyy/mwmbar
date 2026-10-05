import Atomics
import Foundation
import Observation

struct LanDevice: Identifiable, Hashable, Sendable {
  let ip: String
  let hostname: String?
  let services: [String]
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

private final class NetworkSnapshotBox: AtomicReference, @unchecked Sendable {
  let value: NetworkSnapshot
  init(_ value: NetworkSnapshot) { self.value = value }
}

final class NetworkStore: @unchecked Sendable {
  let generation: NetworkGeneration
  private let snapshotRef: ManagedAtomic<NetworkSnapshotBox>

  @MainActor init() {
    self.generation = NetworkGeneration()
    self.snapshotRef = ManagedAtomic<NetworkSnapshotBox>(NetworkSnapshotBox(NetworkSnapshot()))
  }

  @MainActor func snapshot() -> NetworkSnapshot {
    snapshotRef.load(ordering: .acquiring).value
  }

  func commit(_ snap: NetworkSnapshot) {
    snapshotRef.store(NetworkSnapshotBox(snap), ordering: .releasing)
    let gen = generation
    Task { @MainActor in gen.tick &+= 1 }
  }

  /// read, apply, commit. callers must serialize to avoid lost writes.
  func patch(_ apply: (inout NetworkSnapshot) -> Void) {
    var snap = snapshotRef.load(ordering: .acquiring).value
    apply(&snap)
    commit(snap)
  }
}

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

  private var mdnsListener: MdnsListener?
  private var coordinator: ScanCoordinator?

  func startScan() {
    stopScan()
    store.patch { snap in
      snap.scanning = true
      snap.lan = []
    }
    let coord = ScanCoordinator(store: store)
    let mdns = MdnsListener()
    mdns.start(onRecord: { rec in coord.onMdns(rec) })
    mdnsListener = mdns
    coordinator = coord
  }

  func stopScan() {
    mdnsListener?.stop()
    mdnsListener = nil
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
      snap.vpnActive = s.vpnActive
    }
    // public ip is a network round trip; launch it async so the timer
    // tick returns immediately and the summary commit above is not
    // blocked on a remote http call.
    let sampler = self.sampler
    let store = self.store
    Task.detached {
      let ip = await sampler.publicIP()
      store.patch { snap in snap.publicIP = ip }
    }
  }
}

/// serial queue so concurrent mdns callbacks never race on byIp.
private final class ScanCoordinator: @unchecked Sendable {
  private let store: NetworkStore
  private let serial = DispatchQueue(label: "mwmbar.network.coord")
  private var byIp: [String: LanDevice] = [:]

  init(store: NetworkStore) {
    self.store = store
  }

  func onMdns(_ rec: MdnsRecord) {
    serial.async { [self] in
      let existing = byIp[rec.ip]
      let host = existing?.hostname ?? rec.hostname
      var services = Set(existing?.services ?? [])
      services.insert(rec.serviceType)
      byIp[rec.ip] = LanDevice(
        ip: rec.ip,
        hostname: host,
        services: services.sorted())
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
