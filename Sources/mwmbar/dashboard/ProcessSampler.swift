import Darwin
import Foundation

/// one snapshot of a running process. cpuPercent is normalised against the
/// whole machine so values across all processes sum to the overall busy
/// percent (0-100). a value of 100 means every hw thread is pinned by this
/// one process.
struct ProcInfo: Identifiable, Hashable, Sendable {
  let id: pid_t
  let name: String
  let user: String
  let cpuPercent: Double
  let rssBytes: UInt64
  let isSystem: Bool
}

/// polls libproc for live CPU + memory per process. cpu% is the delta of the
/// kernel's total ns against wall clock between two samples, matching the
/// algorithm Activity Monitor uses. designed for ~1.5 s refresh while a
/// dashboard is open; cheap enough to run at that cadence.
final class ProcessSampler: @unchecked Sendable {
  struct Prev {
    let cpuNs: UInt64
    let timestamp: UInt64
  }

  private let lock = NSLock()
  private var previous: [pid_t: Prev] = [:]

  func sample() -> [ProcInfo] {
    let pids = Self.allPids()
    let now = mach_absolute_time()
    let timebase = Self.timebase
    let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    var out: [ProcInfo] = []
    var nextPrev: [pid_t: Prev] = [:]
    out.reserveCapacity(pids.count)
    let prevSnapshot: [pid_t: Prev] = lock.withLock { previous }
    for pid in pids where pid > 0 {
      guard let info = Self.read(pid: pid) else { continue }
      let totalCpuNs =
        (info.userNs + info.system) * UInt64(timebase.numer) / UInt64(timebase.denom)
      var cpuPercent = 0.0
      if let prev = prevSnapshot[pid] {
        let dCpu = totalCpuNs &- prev.cpuNs
        let dWall = (now &- prev.timestamp) * UInt64(timebase.numer) / UInt64(timebase.denom)
        if dWall > 0 {
          cpuPercent = Double(dCpu) / Double(dWall) * 100.0 / cores
        }
      }
      nextPrev[pid] = Prev(cpuNs: totalCpuNs, timestamp: now)
      out.append(
        ProcInfo(
          id: pid,
          name: info.name,
          user: info.user,
          cpuPercent: cpuPercent,
          rssBytes: info.rss,
          isSystem: info.isSystem))
    }
    // drop stale pids so the memo map does not leak over long sessions.
    lock.withLock { previous = nextPrev }
    return out
  }

  func kill(pid: pid_t, force: Bool = false) {
    _ = Darwin.kill(pid, force ? SIGKILL : SIGTERM)
  }

  private static let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
  }()

  private static func allPids() -> [pid_t] {
    let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard n > 0 else { return [] }
    let count = Int(n) / MemoryLayout<pid_t>.size
    var buf = [pid_t](repeating: 0, count: count * 2)
    let written = proc_listpids(
      UInt32(PROC_ALL_PIDS), 0, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard written > 0 else { return [] }
    return Array(buf.prefix(Int(written) / MemoryLayout<pid_t>.size))
  }

  private struct Raw {
    let name: String
    let user: String
    let userUid: uid_t
    let userNs: UInt64
    let system: UInt64
    let rss: UInt64
    let isSystem: Bool
  }

  private static func read(pid: pid_t) -> Raw? {
    var task = proc_taskinfo()
    // stride (not size) + >= compare so the call survives Apple adding
    // trailing fields to proc_taskinfo in a future SDK bump. same for the
    // bsd info call below. per pid failure is a trace and continue since
    // short lived pids disappear between proc_listpids and proc_pidinfo.
    let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
    let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize)
    guard r >= taskSize else { return nil }
    var bsd = proc_bsdshortinfo()
    let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
    let br = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize)
    guard br >= bsdSize else { return nil }
    let name = withUnsafePointer(to: &bsd.pbsi_comm) { ptr -> String in
      ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
        String(cString: $0)
      }
    }
    let uid = bsd.pbsi_uid
    let user = Self.userName(uid: uid) ?? "uid\(uid)"
    // uid < 500 catches root daemons. apple user space processes (Control
    // Center, WindowManager, loginwindow, ...) run as the logged in user so
    // uid alone misses them; the executable path classifier covers the rest.
    let isSystem = uid < 500 || Self.isSystemPath(pid: pid)
    return Raw(
      name: name,
      user: user,
      userUid: uid,
      userNs: task.pti_total_user,
      system: task.pti_total_system,
      rss: task.pti_resident_size,
      isSystem: isSystem)
  }

  private static func isSystemPath(pid: pid_t) -> Bool {
    // 4 * MAXPATHLEN; matches sys/proc_info.h PROC_PIDPATHINFO_MAXSIZE which
    // is not re exported into the Darwin module Swift sees.
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return false }
    let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
      || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
      || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/Library/PrivilegedHelperTools/")
  }

  nonisolated(unsafe) private static var userCache: [uid_t: String] = [:]
  private static let userCacheLock = NSLock()
  private static func userName(uid: uid_t) -> String? {
    userCacheLock.lock()
    defer { userCacheLock.unlock() }
    if let hit = userCache[uid] { return hit }
    guard let pw = getpwuid(uid) else { return nil }
    let name = String(cString: pw.pointee.pw_name)
    userCache[uid] = name
    return name
  }
}
