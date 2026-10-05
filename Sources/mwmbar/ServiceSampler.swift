import Darwin
import Foundation

struct ServiceInfo: Identifiable, Hashable, Sendable {
  let label: String
  let pid: pid_t?
  let lastExitCode: Int?
  let kind: Kind

  enum Kind: Sendable {
    case apple
    case user
  }

  var id: String { label }
  var isRunning: Bool { pid != nil }
}

final class ServiceSampler: @unchecked Sendable {
  func list() -> [ServiceInfo] {
    guard let out = Self.run(["list"]) else { return [] }
    var result: [ServiceInfo] = []
    for line in out.split(separator: "\n").dropFirst() {
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 3 else { continue }
      let label = String(parts[2])
      // skip macOS auto-generated per-GUI-app jobs. they are not services
      // in any user-controllable sense; starting / stopping them maps onto
      // launching / quitting the owning app via LaunchServices.
      if label.hasPrefix("application.") { continue }
      let pidStr = parts[0]
      let statusStr = parts[1]
      let pid: pid_t? = pidStr == "-" ? nil : pid_t(pidStr)
      let status: Int? = statusStr == "-" ? nil : Int(statusStr)
      result.append(
        ServiceInfo(
          label: label, pid: pid, lastExitCode: status, kind: Self.classify(label)))
    }
    return result
  }

  func start(label: String) { _ = Self.run(["start", label]) }
  func stop(label: String) { _ = Self.run(["stop", label]) }
  func restart(label: String) {
    let uid = getuid()
    _ = Self.run(["kickstart", "-k", "gui/\(uid)/\(label)"])
  }

  private static func classify(_ label: String) -> ServiceInfo.Kind {
    label.hasPrefix("com.apple.") ? .apple : .user
  }

  @discardableResult
  private static func run(_ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }
}
