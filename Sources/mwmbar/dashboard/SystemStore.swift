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

/// reference wrapped snapshot so the atomic swap works on a single word.
private final class SystemSnapshotBox: @unchecked Sendable {
  let value: SystemSnapshot
  init(_ value: SystemSnapshot) { self.value = value }
}

/// atomic snapshot store. writers passRetained a new box and exchange;
/// readers (main only) load lock free. old boxes are released on main so
/// no reader can dereference a freed pointer in the same runloop cycle.
final class SystemStore: @unchecked Sendable {
  let generation: SystemGeneration
  private let snapshotPtr: ManagedAtomic<UInt>

  @MainActor init() {
    self.generation = SystemGeneration()
    let box = SystemSnapshotBox(SystemSnapshot())
    let raw = Unmanaged.passRetained(box).toOpaque()
    self.snapshotPtr = ManagedAtomic<UInt>(UInt(bitPattern: raw))
  }

  deinit {
    let raw = snapshotPtr.load(ordering: .relaxed)
    if let ptr = UnsafeRawPointer(bitPattern: raw) {
      Unmanaged<SystemSnapshotBox>.fromOpaque(ptr).release()
    }
  }

  @MainActor func snapshot() -> SystemSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<SystemSnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }

  func commit(_ snap: SystemSnapshot) {
    let newBox = SystemSnapshotBox(snap)
    let newRaw = Unmanaged.passRetained(newBox).toOpaque()
    let oldRawInt = snapshotPtr.exchange(
      UInt(bitPattern: newRaw), ordering: .acquiringAndReleasing)
    let gen = generation
    Task { @MainActor in
      if let oldPtr = UnsafeRawPointer(bitPattern: oldRawInt) {
        Unmanaged<SystemSnapshotBox>.fromOpaque(oldPtr).release()
      }
      gen.tick &+= 1
    }
  }
}
