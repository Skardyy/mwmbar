import Foundation

enum UpdateStatus: Equatable {
  case idle
  case checking
  case upToDate
  case available(current: String, latest: String)
  case installing
  case installed
  case failed(String)
}

@MainActor
final class UpdateController: ObservableObject {
  @Published private(set) var status: UpdateStatus = .idle

  // two separate steps on purpose: checking never installs anything by
  // itself, so a stray click can't trigger an upgrade the user never saw
  // the version number for.
  func check() {
    guard status != .checking, status != .installing else { return }
    status = .checking
    Task.detached { [weak self] in
      let result = Self.outdated()
      await MainActor.run { self?.status = result }
    }
  }

  func install() {
    guard case .available = status else { return }
    status = .installing
    Task.detached { [weak self] in
      let result = Self.upgrade()
      await MainActor.run { self?.status = result }
    }
  }

  // skardyy/mwmbar is a custom tap, not homebrew-core: brew only reads
  // whatever that tap's own git checkout has on disk, so pulling it is
  // what actually makes a new release visible, same as running
  // `cd $(brew --repo skardyy/mwmbar) && git pull` by hand.
  nonisolated private static func pullTap() -> Bool {
    guard let repoOutput = run(["--repo", "skardyy/mwmbar"]) else { return false }
    let repoPath = repoOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !repoPath.isEmpty else { return false }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", repoPath, "pull"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      Log.bar.warning("mwmbar update: git pull launch failed: \(error)")
      return false
    }
    proc.waitUntilExit()
    return proc.terminationStatus == 0
  }

  nonisolated private static func outdated() -> UpdateStatus {
    guard pullTap() else { return .failed("couldn't refresh the mwmbar tap") }
    guard let output = run(["outdated", "--json=v2", "mwmbar"]) else {
      return .failed("couldn't check brew")
    }
    struct Outdated: Decodable {
      struct Formula: Decodable {
        let installed_versions: [String]
        let current_version: String
      }
      let formulae: [Formula]
    }
    guard let data = output.stdout.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Outdated.self, from: data)
    else {
      Log.bar.warning("mwmbar update: unexpected brew outdated output: \(output.stdout)")
      return .failed("couldn't read brew output")
    }
    guard let formula = decoded.formulae.first else { return .upToDate }
    return .available(
      current: formula.installed_versions.first ?? "?", latest: formula.current_version)
  }

  nonisolated private static func upgrade() -> UpdateStatus {
    guard let output = run(["upgrade", "mwmbar"]) else {
      return .failed("couldn't launch brew")
    }
    guard output.exitCode == 0 else {
      Log.bar.warning("mwmbar update: brew upgrade failed: \(output.stdout)\(output.stderr)")
      return .failed("brew upgrade failed")
    }
    return .installed
  }

  private struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  nonisolated private static func run(_ arguments: [String]) -> RunResult? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["brew"] + arguments
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = SystemPath.resolved
    proc.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
      try proc.run()
    } catch {
      Log.bar.warning("mwmbar update: brew launch failed: \(error)")
      return nil
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return RunResult(
      exitCode: proc.terminationStatus,
      stdout: String(data: outData, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? "")
  }
}
