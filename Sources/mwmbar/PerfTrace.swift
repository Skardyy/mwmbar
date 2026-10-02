import Darwin
import Foundation

/// lightweight tracing for compositor and bar pipeline latency.
/// enabled when MWMBAR_PERF is a non empty env var. all APIs are a no op
/// when disabled so the hot paths stay cheap in release use.
///
/// each stamp carries a (kind, seq) tuple. upstream handlers call
/// `begin(kind:parent:)` to open a span, downstream handlers forward the
/// same seq via `handoff(from:kind:)` so grep can trace an aerospace
/// event all the way to a BarView re render.
enum PerfTrace {
  static let enabled: Bool = {
    guard let v = ProcessInfo.processInfo.environment["MWMBAR_PERF"] else { return false }
    return !v.isEmpty
  }()

  // monotonic ns since boot via mach wall clock, converted once per sample.
  @inline(__always)
  static func now() -> UInt64 {
    let raw = mach_absolute_time()
    let tb = timebase
    return raw * UInt64(tb.numer) / UInt64(tb.denom)
  }

  private static let timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return t
  }()

  final class Span: @unchecked Sendable {
    let kind: String
    let seq: UInt64
    let startNs: UInt64
    var parent: UInt64?

    init(kind: String, seq: UInt64, startNs: UInt64, parent: UInt64?) {
      self.kind = kind
      self.seq = seq
      self.startNs = startNs
      self.parent = parent
    }
  }

  // monotonic sequence stamped on every new span so a reader can group
  // callbacks that fan out from the same source event.
  nonisolated(unsafe) private static var counter: UInt64 = 0
  nonisolated(unsafe) private static var counterLock = os_unfair_lock()
  private static func nextSeq() -> UInt64 {
    os_unfair_lock_lock(&counterLock)
    defer { os_unfair_lock_unlock(&counterLock) }
    counter &+= 1
    return counter
  }

  static func begin(_ kind: String, parent: UInt64? = nil) -> Span? {
    guard enabled else { return nil }
    return Span(kind: kind, seq: nextSeq(), startNs: now(), parent: parent)
  }

  static func end(_ span: Span?, detail: String? = nil) {
    guard enabled, let span else { return }
    let elapsedUs = (now() - span.startNs) / 1_000
    let parent = span.parent.map { " parent=\($0)" } ?? ""
    let extra = detail.map { " \($0)" } ?? ""
    Log.bar.debug(
      "[perf] kind=\(span.kind) seq=\(span.seq)\(parent) us=\(elapsedUs)\(extra)")
  }

  // emits a point in time marker without opening a span. useful for the
  // moments where there is no duration to measure (an observable write).
  static func mark(_ kind: String, parent: UInt64? = nil, detail: String? = nil) {
    guard enabled else { return }
    let seq = nextSeq()
    let parentStr = parent.map { " parent=\($0)" } ?? ""
    let extra = detail.map { " \($0)" } ?? ""
    Log.bar.debug("[perf] mark=\(kind) seq=\(seq)\(parentStr)\(extra)")
  }

  /// counters bucketed per kind. flushed on demand via `dumpCounters`.
  nonisolated(unsafe) private static var counts: [String: UInt64] = [:]
  nonisolated(unsafe) private static var countsLock = os_unfair_lock()

  static func incr(_ kind: String, by amount: UInt64 = 1) {
    guard enabled else { return }
    os_unfair_lock_lock(&countsLock)
    counts[kind, default: 0] &+= amount
    os_unfair_lock_unlock(&countsLock)
  }

  /// SwiftUI friendly counter: safe to drop in a ViewBuilder body because
  /// it returns a value (ignored) instead of Void.
  @discardableResult
  static func tick(_ kind: String) -> Int {
    incr(kind)
    return 0
  }

  static func dumpCounters() {
    guard enabled else { return }
    os_unfair_lock_lock(&countsLock)
    let snapshot = counts
    counts.removeAll(keepingCapacity: true)
    os_unfair_lock_unlock(&countsLock)
    let line = snapshot.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    Log.bar.debug("[perf] counters \(line)")
  }
}
