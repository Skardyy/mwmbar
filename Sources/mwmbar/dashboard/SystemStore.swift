import Atomics
import Foundation
import Observation

struct SystemLoad: Equatable, Sendable {
  var cpuBusy: Double = 0
  var memUsedBytes: UInt64 = 0
  var memTotalBytes: UInt64 = 1
  var coreCount: Int = 1
  var memUsedFraction: Double { Double(memUsedBytes) / Double(memTotalBytes) }
}

/// immutable sample snapshot; written off main, read on main.
struct SystemSnapshot: Sendable {
  var load: SystemLoad = SystemLoad()
  var procs: [ProcInfo] = []
}

/// observation trigger bumped after every snapshot commit so views can
/// resubscribe.
@MainActor
@Observable
final class SystemGeneration {
  var tick: UInt64 = 0
}

private final class SystemSnapshotBox: AtomicReference, @unchecked Sendable {
  let value: SystemSnapshot
  init(_ value: SystemSnapshot) { self.value = value }
}

/// atomic snapshot store. writers swap in a new box via AtomicReference;
/// readers load lock free. ARC releases the old box after the swap.
final class SystemStore: @unchecked Sendable {
  let generation: SystemGeneration
  private let snapshotRef: ManagedAtomic<SystemSnapshotBox>

  @MainActor init() {
    self.generation = SystemGeneration()
    self.snapshotRef = ManagedAtomic<SystemSnapshotBox>(SystemSnapshotBox(SystemSnapshot()))
  }

  @MainActor func snapshot() -> SystemSnapshot {
    snapshotRef.load(ordering: .acquiring).value
  }

  func commit(_ snap: SystemSnapshot) {
    snapshotRef.store(SystemSnapshotBox(snap), ordering: .releasing)
    let gen = generation
    Task { @MainActor in gen.tick &+= 1 }
  }
}
