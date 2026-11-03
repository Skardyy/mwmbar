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
    let commandByPid = resolveCommands(pids: pids(in: output))
    var seen = Set<String>()
    var out: [PortInfo] = []
    for line in output.split(separator: "\n").dropFirst() {
      guard var info = parse(line) else { continue }
      if let full = commandByPid[info.pid] {
        if systemPrefixes.contains(where: { full.hasPrefix($0) }) { continue }
        info.command = (full as NSString).lastPathComponent
      }
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

  // lsof's own COMMAND column truncates to ~9 chars and shows the kernel
  // process name, not the real executable (e.g. a node-hosted daemon like
  // prettierd shows up as plain "node"); ps -o comm= gives the full path.
  private static func resolveCommands(pids: Set<pid_t>) -> [pid_t: String] {
    guard !pids.isEmpty else { return [:] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-axo", "pid=,comm="]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      Log.network.warning("ps launch failed: \(error)")
      return [:]
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    var out: [pid_t: String] = [:]
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
      guard let pid = pid_t(trimmed[..<spaceIdx]), pids.contains(pid) else { continue }
      out[pid] = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(
        in: .whitespaces)
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
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-i", "-P", "-n"]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      // periodic sampler on a refresh timer: trace and continue rather
      // than crash the daemon over a transient lsof launch failure.
      Log.network.warning("lsof launch failed: \(error)")
      return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }
}
