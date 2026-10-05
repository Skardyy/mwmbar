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

/// background timer; owner controls start / stop.
final class ServiceRefresher: @unchecked Sendable {
  private let store: ServiceStore
  private let sampler: ServiceSampler
  private let queue = DispatchQueue(label: "mwmbar.services", qos: .utility)
  private let interval: TimeInterval
  private var timer: DispatchSourceTimer?

  init(store: ServiceStore, sampler: ServiceSampler, interval: TimeInterval = 5.0) {
    self.store = store
    self.sampler = sampler
    self.interval = interval
  }

  func start() {
    stop()
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: interval)
    t.setEventHandler { [weak self] in self?.refreshOnce() }
    t.resume()
    timer = t
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  /// forces an immediate refresh outside the periodic cadence.
  func kick() {
    queue.async { [weak self] in self?.refreshOnce() }
  }

  private func refreshOnce() {
    let items = sampler.list()
    store.commit(ServiceSnapshot(services: items))
  }
}
