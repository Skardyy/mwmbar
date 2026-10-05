import Darwin
import Foundation

struct ServiceInfo: Identifiable, Hashable, Sendable {
  let label: String
  let pid: pid_t?
  let lastExitCode: Int?
  let kind: Kind
  let state: State
  let plistPath: String?
  let scope: Scope

  enum Kind: Sendable {
    case apple
    case user
  }

  enum State: Sendable {
    case running
    case loadedStopped
    case unloaded
  }

  enum Scope: Sendable {
    case userAgent
    case systemAgent
    case systemDaemon
  }

  var id: String { label }
  var isRunning: Bool { pid != nil }
}

final class ServiceSampler: @unchecked Sendable {
  func list() -> [ServiceInfo] {
    let loaded = loadedByLabel()
    let plists = scanPlistDirs()
    var byLabel: [String: ServiceInfo] = [:]
    for info in plists {
      byLabel[info.label] = info
    }
    for (label, l) in loaded {
      let existing = byLabel[label]
      let state: ServiceInfo.State = l.pid != nil ? .running : .loadedStopped
      byLabel[label] = ServiceInfo(
        label: label,
        pid: l.pid,
        lastExitCode: l.exit,
        kind: existing?.kind ?? Self.classify(label),
        state: state,
        plistPath: existing?.plistPath,
        scope: existing?.scope ?? .userAgent)
    }
    return Array(byLabel.values)
  }

  func enable(label: String, plistPath: String) {
    guard let scope = Self.scope(forPlistPath: plistPath) else { return }
    switch scope {
    case .systemAgent, .systemDaemon:
      logResult("enable", label, Self.run(["bootstrap", "system", plistPath]))
    case .userAgent:
      let target = "gui/\(getuid())/\(label)"
      _ = Self.run(["enable", target])
      logResult(
        "enable", label, Self.run(["bootstrap", "gui/\(getuid())", plistPath]))
    }
  }

  func disable(label: String) {
    let target = "gui/\(getuid())/\(label)"
    _ = Self.run(["disable", target])
    logResult("disable", label, Self.run(["bootout", target]))
  }

  func start(label: String) { logResult("start", label, Self.run(["kickstart", target(label)])) }
  func stop(label: String) { logResult("stop", label, Self.run(["kill", "TERM", target(label)])) }
  func restart(label: String) {
    logResult("restart", label, Self.run(["kickstart", "-k", target(label)]))
  }

  private func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

  private func logResult(_ op: String, _ label: String, _ r: RunResult) {
    guard r.exit != 0 else { return }
    Log.bar.warning(
      "launchctl \(op) \(label) exit=\(r.exit) stderr=\(r.stderr.prefix(200))")
  }

  // -- scan ---------------------------------------------------------------

  private struct Loaded {
    let pid: pid_t?
    let exit: Int?
  }

  private func loadedByLabel() -> [String: Loaded] {
    guard let out = Self.run(["list"]).stdout else { return [:] }
    var map: [String: Loaded] = [:]
    for line in out.split(separator: "\n").dropFirst() {
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 3 else { continue }
      let label = String(parts[2])
      if label.hasPrefix("application.") { continue }
      let pid: pid_t? = parts[0] == "-" ? nil : pid_t(parts[0])
      let exit: Int? = parts[1] == "-" ? nil : Int(parts[1])
      map[label] = Loaded(pid: pid, exit: exit)
    }
    return map
  }

  private struct ScanDir {
    let path: String
    let scope: ServiceInfo.Scope
  }

  private func scanPlistDirs() -> [ServiceInfo] {
    let home = NSHomeDirectory()
    var dirs: [ScanDir] = [
      ScanDir(path: "\(home)/Library/LaunchAgents", scope: .userAgent),
      ScanDir(path: "/Library/LaunchAgents", scope: .systemAgent),
      ScanDir(path: "/Library/LaunchDaemons", scope: .systemDaemon),
    ]
    dirs.append(contentsOf: Self.bundledPlistDirs())
    var seen: [String: ServiceInfo] = [:]
    for dir in dirs {
      guard
        let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
      else { continue }
      for entry in entries {
        guard entry.hasSuffix(".plist") else { continue }
        let label = String(entry.dropLast(6))
        if label.hasPrefix("application.") { continue }
        // first wins: user ~/Library beats system /Library beats bundled.
        if seen[label] != nil { continue }
        seen[label] = ServiceInfo(
          label: label,
          pid: nil,
          lastExitCode: nil,
          kind: Self.classify(label),
          state: .unloaded,
          plistPath: "\(dir.path)/\(entry)",
          scope: dir.scope)
      }
    }
    return Array(seen.values)
  }

  // walk /Library/Application Support/<Vendor>/<Family>/*.app/Contents/
  // Library/{LaunchAgents,LaunchDaemons} since many apps ship bundled plists.
  private static func bundledPlistDirs() -> [ScanDir] {
    let root = "/Library/Application Support"
    guard let vendors = try? FileManager.default.contentsOfDirectory(atPath: root) else {
      return []
    }
    var out: [ScanDir] = []
    for vendor in vendors {
      let vendorPath = "\(root)/\(vendor)"
      guard let families = try? FileManager.default.contentsOfDirectory(atPath: vendorPath)
      else { continue }
      for family in families {
        let familyPath = "\(vendorPath)/\(family)"
        guard let apps = try? FileManager.default.contentsOfDirectory(atPath: familyPath)
        else { continue }
        for app in apps where app.hasSuffix(".app") {
          let base = "\(familyPath)/\(app)/Contents/Library"
          out.append(ScanDir(path: "\(base)/LaunchAgents", scope: .systemAgent))
          out.append(ScanDir(path: "\(base)/LaunchDaemons", scope: .systemDaemon))
        }
      }
    }
    return out
  }

  private static func scope(forPlistPath path: String) -> ServiceInfo.Scope? {
    if path.hasPrefix("\(NSHomeDirectory())/Library/LaunchAgents") { return .userAgent }
    if path.hasPrefix("/Library/LaunchAgents") { return .systemAgent }
    if path.hasPrefix("/Library/LaunchDaemons") { return .systemDaemon }
    if path.contains("/Library/LaunchDaemons/") { return .systemDaemon }
    if path.contains("/Library/LaunchAgents/") { return .systemAgent }
    return nil
  }

  private static func classify(_ label: String) -> ServiceInfo.Kind {
    label.hasPrefix("com.apple.") ? .apple : .user
  }

  // -- shell --------------------------------------------------------------

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
    // drain both before waitUntilExit; otherwise a child that writes more
    // than the pipe buffer (~64KB) blocks waiting for a reader while the
    // parent blocks waiting for exit.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return RunResult(
      exit: proc.terminationStatus,
      stdout: String(data: outData, encoding: .utf8),
      stderr: String(data: errData, encoding: .utf8) ?? "")
  }
}
