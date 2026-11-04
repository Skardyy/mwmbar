import Foundation

enum PortProto: String, Sendable {
  case tcp = "TCP"
  case udp = "UDP"
}

struct PortInfo: Identifiable, Sendable, Equatable {
  let proto: PortProto
  let port: Int
  let pid: pid_t
  var command: String
  var folder: String?
  var age: String?
  var id: String { "\(proto.rawValue):\(port):\(pid)" }
}

enum PortSampler {
  // paths under these roots are macOS itself (Continuity/Handoff daemons,
  // Control Center, etc.), never something the user launched; filtered out
  // so the list only shows ports an actual app/dev process is holding.
  private static let systemPrefixes = [
    "/usr/libexec/", "/System/", "/sbin/", "/usr/sbin/",
  ]

  // only udp (always bound) and listening tcp sockets are kept, so active
  // outbound tcp connections do not drown out the ports actually bound.
  static func sample() -> [PortInfo] {
    guard let output = run() else { return [] }
    let wanted = pids(in: output)
    let processes = resolveProcesses(pids: wanted)
    let cwds = resolveCwds(pids: wanted)
    var seen = Set<String>()
    var out: [PortInfo] = []
    for line in output.split(separator: "\n").dropFirst() {
      guard var info = parse(line) else { continue }
      if let proc = processes[info.pid] {
        if systemPrefixes.contains(where: { proc.command.hasPrefix($0) }) { continue }
        info.command = (proc.command as NSString).lastPathComponent
        info.age = proc.age
      }
      info.folder = cwds[info.pid].map { ($0 as NSString).lastPathComponent }
      guard seen.insert(info.id).inserted else { continue }
      out.append(info)
    }
    return out
  }

  private static func pids(in output: String) -> Set<pid_t> {
    var out = Set<pid_t>()
    for line in output.split(separator: "\n").dropFirst() {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      if fields.count > 1, let pid = pid_t(fields[1]) { out.insert(pid) }
    }
    return out
  }

  private struct ProcessMeta {
    let command: String
    let age: String?
  }

  // lsof's own COMMAND column truncates to ~9 chars and shows the kernel
  // process name, not the real executable (e.g. a node-hosted daemon like
  // prettierd shows up as plain "node"); ps -o comm= gives the full path.
  // etime (elapsed since start) is pulled in the same call since ps already
  // has to walk every process either way.
  private static func resolveProcesses(pids: Set<pid_t>) -> [pid_t: ProcessMeta] {
    guard !pids.isEmpty else { return [:] }
    guard let text = run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,etime=,comm="]) else {
      return [:]
    }
    var out: [pid_t: ProcessMeta] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 3, let pid = pid_t(fields[0]), pids.contains(pid) else { continue }
      let command = fields[2...].joined(separator: " ")
      out[pid] = ProcessMeta(command: command, age: formatAge(String(fields[1])))
    }
    return out
  }

  // ps etime is "[[DD-]HH:]MM:SS"; shown as the coarsest unit so "started
  // 2d ago" reads at a glance instead of a full duration stopwatch.
  private static func formatAge(_ etime: String) -> String? {
    var days = 0
    var rest = etime
    if let dashIdx = etime.firstIndex(of: "-") {
      days = Int(etime[..<dashIdx]) ?? 0
      rest = String(etime[etime.index(after: dashIdx)...])
    }
    let parts = rest.split(separator: ":").compactMap { Int($0) }
    guard !parts.isEmpty else { return nil }
    let hours = days > 0 || parts.count == 3 ? parts[parts.count - 3] : 0
    let minutes = parts.count >= 2 ? parts[parts.count - 2] : 0
    if days > 0 { return "\(days)d ago" }
    if hours > 0 { return "\(hours)h ago" }
    if minutes > 0 { return "\(minutes)m ago" }
    return "just now"
  }

  // one batched "which pid has which cwd" lookup instead of forking lsof
  // once per pid; NAME is joined back together since a path can contain
  // spaces, which a plain whitespace split would otherwise cut apart.
  private static func resolveCwds(pids: Set<pid_t>) -> [pid_t: String] {
    guard !pids.isEmpty else { return [:] }
    guard let text = run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-a", "-d", "cwd", "-n", "-P"])
    else { return [:] }
    var out: [pid_t: String] = [:]
    for line in text.split(separator: "\n").dropFirst() {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 9, let pid = pid_t(fields[1]), pids.contains(pid) else { continue }
      out[pid] = fields[8...].joined(separator: " ")
    }
    return out
  }

  private static func parse(_ line: Substring) -> PortInfo? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [STATE]
    guard fields.count >= 9 else { return nil }
    let command = fields[0]
    guard let pid = pid_t(fields[1]) else { return nil }
    let proto: PortProto
    switch fields[7] {
    case "TCP": proto = .tcp
    case "UDP": proto = .udp
    default: return nil
    }
    let name = fields[8]
    if proto == .tcp {
      let state = fields.count > 9 ? fields[9] : ""
      guard state.contains("LISTEN") else { return nil }
    }
    // "*:5353", "127.0.0.1:5000", "[::1]:514" -> take the port after the
    // last colon, stripping a bracketed ipv6 host first if present.
    let local = name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? name
    guard let colonIdx = local.lastIndex(of: ":") else { return nil }
    let portStr = local[local.index(after: colonIdx)...]
    guard let port = Int(portStr) else { return nil }
    return PortInfo(proto: proto, port: port, pid: pid, command: command)
  }

  private static func run() -> String? {
    run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-i", "-P", "-n"])
  }

  private static func run(_ executable: URL, _ arguments: [String]) -> String? {
    let proc = Process()
    proc.executableURL = executable
    proc.arguments = arguments
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      // periodic sampler on a refresh timer: trace and continue rather
      // than crash the daemon over a transient subprocess launch failure.
      Log.network.warning("\(executable.lastPathComponent) launch failed: \(error)")
      return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }
}
