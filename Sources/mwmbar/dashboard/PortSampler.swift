import Foundation

enum PortProto: String, Sendable {
  case tcp = "TCP"
  case udp = "UDP"
}

struct PortInfo: Identifiable, Sendable, Equatable {
  let proto: PortProto
  let port: Int
  let pid: pid_t
  let command: String
  var id: String { "\(proto.rawValue):\(port):\(pid)" }
}

enum PortSampler {
  // only udp (always bound) and listening tcp sockets are kept, so active
  // outbound tcp connections do not drown out the ports actually bound.
  static func sample() -> [PortInfo] {
    guard let output = run() else { return [] }
    var seen = Set<String>()
    var out: [PortInfo] = []
    for line in output.split(separator: "\n").dropFirst() {
      guard let info = parse(line) else { continue }
      guard seen.insert(info.id).inserted else { continue }
      out.append(info)
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
