import Atomics
import Foundation
import Observation

struct ServiceSnapshot: Sendable {
  var services: [ServiceInfo] = []
}

enum ServiceAction: Sendable {
  case start(String)
  case stop(String)
  case restart(String)
}

@MainActor
@Observable
final class ServiceGeneration {
  var tick: UInt64 = 0
}

private final class ServiceSnapshotBox: @unchecked Sendable {
  let value: ServiceSnapshot
  init(_ value: ServiceSnapshot) { self.value = value }
}

final class ServiceStore: @unchecked Sendable {
  let generation: ServiceGeneration
  private let snapshotPtr: ManagedAtomic<UInt>

  @MainActor init() {
    self.generation = ServiceGeneration()
    let box = ServiceSnapshotBox(ServiceSnapshot())
    let raw = Unmanaged.passRetained(box).toOpaque()
    self.snapshotPtr = ManagedAtomic<UInt>(UInt(bitPattern: raw))
  }

  deinit {
    let raw = snapshotPtr.load(ordering: .relaxed)
    if let ptr = UnsafeRawPointer(bitPattern: raw) {
      Unmanaged<ServiceSnapshotBox>.fromOpaque(ptr).release()
    }
  }

  @MainActor func snapshot() -> ServiceSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<ServiceSnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }

  func commit(_ snap: ServiceSnapshot) {
    let newBox = ServiceSnapshotBox(snap)
    let newRaw = Unmanaged.passRetained(newBox).toOpaque()
    let oldRawInt = snapshotPtr.exchange(
      UInt(bitPattern: newRaw), ordering: .acquiringAndReleasing)
    let gen = generation
    Task { @MainActor in
      if let oldPtr = UnsafeRawPointer(bitPattern: oldRawInt) {
        Unmanaged<ServiceSnapshotBox>.fromOpaque(oldPtr).release()
      }
      gen.tick &+= 1
    }
  }
}

/// drives ServiceStore from a background queue. owns the sampler and
/// debounces refresh requests so bursty actions (start / stop / restart)
/// coalesce into a single launchctl list call.
final class ServiceRefresher: @unchecked Sendable {
  private let store: ServiceStore
  private let sampler: ServiceSampler
  private let queue = DispatchQueue(label: "mwmbar.services", qos: .utility)
  private let interval: TimeInterval

  init(store: ServiceStore, sampler: ServiceSampler, interval: TimeInterval = 5.0) {
    self.store = store
    self.sampler = sampler
    self.interval = interval
  }

  func start() {
    queue.async { [weak self] in self?.loop() }
  }

  /// request an immediate refresh outside the periodic cadence. use after a
  /// start / stop / restart so the UI reflects new state quickly.
  func kick() {
    queue.async { [weak self] in self?.refreshOnce() }
  }

  private func loop() {
    while true {
      refreshOnce()
      Thread.sleep(forTimeInterval: interval)
    }
  }

  private func refreshOnce() {
    let items = sampler.list()
    store.commit(ServiceSnapshot(services: items))
  }
}
