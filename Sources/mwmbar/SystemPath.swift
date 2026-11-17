import Foundation

// a launchd managed process gets a bare PATH missing homebrew entirely,
// and /opt/homebrew/bin is Apple Silicon only anyway (Intel's brew lives
// at /usr/local/bin). path_helper reads /etc/paths plus /etc/paths.d/*
// (where homebrew installs its own entry) and returns the same PATH a
// login shell would get.
enum SystemPath {
  static let resolved: String = {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/libexec/path_helper")
    proc.arguments = ["-s"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    guard (try? proc.run()) != nil else {
      return ProcessInfo.processInfo.environment["PATH"] ?? ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("PATH=\"") }),
      let value = line.split(separator: "\"").dropFirst().first
    else { return ProcessInfo.processInfo.environment["PATH"] ?? "" }
    return String(value)
  }()
}
