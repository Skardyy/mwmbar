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
    guard let out = Self.run(["list"]).stdout else { return [] }
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

  func start(label: String) { logResult("start", label, Self.run(["kickstart", target(label)])) }
  func stop(label: String) { logResult("stop", label, Self.run(["bootout", target(label)])) }
  func restart(label: String) {
    logResult("restart", label, Self.run(["kickstart", "-k", target(label)]))
  }

  private func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

  private func logResult(_ op: String, _ label: String, _ r: RunResult) {
    guard r.exit != 0 else { return }
    Log.bar.warning(
      "launchctl \(op) \(label) exit=\(r.exit) stderr=\(r.stderr.prefix(200))")
  }

  private static func classify(_ label: String) -> ServiceInfo.Kind {
    label.hasPrefix("com.apple.") ? .apple : .user
  }

  private struct RunResult {
    let exit: Int32
    let stdout: String?
    let stderr: String
  }

  private static func run(_ args: [String]) -> RunResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
      try proc.run()
    } catch {
      return RunResult(exit: -1, stdout: nil, stderr: "\(error)")
    }
    // read both pipes to end before waitUntilExit; otherwise a child that
    // writes more than the pipe buffer (~64KB) can block waiting for a
    // reader while the parent blocks waiting for exit.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return RunResult(
      exit: proc.terminationStatus,
      stdout: String(data: outData, encoding: .utf8),
      stderr: String(data: errData, encoding: .utf8) ?? "")
  }
}
