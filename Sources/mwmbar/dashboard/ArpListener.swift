import Foundation

/// passive listener that pipes tcpdump arp output and streams every
/// observed (ip, mac) pair to the caller. relies on tcpdump already
/// having BPF access; if not installed via ChmodBPF the process exits
/// with a permission error, surfaced via onError.
final class ArpListener: @unchecked Sendable {
  private let lock = NSLock()
  private var proc: Process?

  func start(
    interface: String,
    onDevice: @escaping @Sendable (String, String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) {
    stop()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
    p.arguments = ["-i", interface, "-l", "-n", "-e", "-q", "arp"]
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    outPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      for raw in text.split(separator: "\n") {
        if let (ip, mac) = Self.parse(String(raw)) {
          onDevice(ip, mac)
        }
      }
    }
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { onError(trimmed) }
    }
    p.terminationHandler = { _ in
      outPipe.fileHandleForReading.readabilityHandler = nil
      errPipe.fileHandleForReading.readabilityHandler = nil
    }
    do {
      try p.run()
    } catch {
      onError("tcpdump launch failed: \(error.localizedDescription)")
      return
    }
    lock.withLock { self.proc = p }
  }

  func stop() {
    let old: Process? = lock.withLock {
      let p = proc
      proc = nil
      return p
    }
    old?.terminate()
  }

  var isRunning: Bool {
    lock.withLock { proc?.isRunning == true }
  }

  // tcpdump -e arp lines look like:
  //   13:58:12.345 aa:bb:cc:dd:ee:ff > ff:ff:ff:ff:ff:ff, ARP, Request who-has 10.0.0.1 tell 10.0.0.2, length 46
  //   13:58:12.346 aa:bb:cc:dd:ee:ff > 11:22:33:44:55:66, ARP, Reply 10.0.0.2 is-at aa:bb:cc:dd:ee:ff, length 46
  // for both forms the sender's mac is the eth src (second token); the
  // sender's ip is after "tell " for requests or after "Reply " for replies.
  private static func parse(_ line: String) -> (String, String)? {
    let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
    guard tokens.count >= 2 else { return nil }
    let srcMac = String(tokens[1])
    guard srcMac.filter({ $0 == ":" }).count == 5 else { return nil }

    if let range = line.range(of: "tell ") {
      let tail = line[range.upperBound...]
      let ip = tail.prefix { $0 != "," && $0 != " " }
      if isIPv4(String(ip)) { return (String(ip), srcMac) }
    }
    if let range = line.range(of: "Reply ") {
      let tail = line[range.upperBound...]
      let ip = tail.prefix { $0 != " " }
      if isIPv4(String(ip)) { return (String(ip), srcMac) }
    }
    if let range = line.range(of: "Announcement ") {
      let tail = line[range.upperBound...]
      let ip = tail.prefix { $0 != " " && $0 != "," }
      if isIPv4(String(ip)) { return (String(ip), srcMac) }
    }
    return nil
  }

  private static func isIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } == true }
  }
}
