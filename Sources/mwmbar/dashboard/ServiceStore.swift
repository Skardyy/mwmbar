import Atomics
import Foundation
import Observation

struct ServiceSnapshot: Sendable {
  var services: [ServiceInfo] = []
}

enum ServiceAction: Sendable {
  case enable(String, String)
  case disable(String)
  case start(String)
  case stop(String)
  case restart(String)
}

@MainActor
@Observable
final class ServiceGeneration {
  var tick: UInt64 = 0
}

private final class ServiceSnapshotBox: AtomicReference, @unchecked Sendable {
  let value: ServiceSnapshot
  init(_ value: ServiceSnapshot) { self.value = value }
}

final class ServiceStore: @unchecked Sendable {
  let generation: ServiceGeneration
  private let snapshotRef: ManagedAtomic<ServiceSnapshotBox>

  @MainActor init() {
    self.generation = ServiceGeneration()
    self.snapshotRef = ManagedAtomic<ServiceSnapshotBox>(ServiceSnapshotBox(ServiceSnapshot()))
  }

  @MainActor func snapshot() -> ServiceSnapshot {
    snapshotRef.load(ordering: .acquiring).value
  }

  func commit(_ snap: ServiceSnapshot) {
    snapshotRef.store(ServiceSnapshotBox(snap), ordering: .releasing)
    let gen = generation
    Task { @MainActor in gen.tick &+= 1 }
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
