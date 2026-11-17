import Foundation

struct StorageItem: Identifiable, Sendable, Equatable {
  enum Clear: Sendable, Equatable {
    case removePath(String)
    case dockerRemoveImage(String)
    case dockerRemoveVolume(String)
    case dockerPruneBuildCache
  }

  let id: String
  let title: String
  let tag: String
  let sizeBytes: Int64
  let clear: Clear
}

enum StorageScanner {
  private struct GlobalSpec {
    let label: String
    let path: String
    let tag: String
  }

  // each entry is one bounded du on a known cache directory.
  private static let globals: [GlobalSpec] = [
    GlobalSpec(label: "npm cache", path: "~/.npm", tag: "npm"),
    GlobalSpec(label: "pnpm store", path: "~/Library/pnpm/store", tag: "pnpm"),
    GlobalSpec(label: "cargo registry", path: "~/.cargo/registry", tag: "cargo"),
    GlobalSpec(label: "go module cache", path: "~/go/pkg/mod", tag: "go"),
    GlobalSpec(label: "go build cache", path: "~/Library/Caches/go-build", tag: "go"),
    GlobalSpec(label: "pip cache", path: "~/Library/Caches/pip", tag: "pip"),
    GlobalSpec(label: "homebrew cache", path: "~/Library/Caches/Homebrew", tag: "brew"),
    GlobalSpec(label: "rattler cache", path: "~/Library/Caches/rattler", tag: "rattler"),
    GlobalSpec(label: "playwright browsers", path: "~/Library/Caches/ms-playwright", tag: "playwright"),
    GlobalSpec(label: "terragrunt cache", path: "~/Library/Caches/terragrunt", tag: "terragrunt"),
    GlobalSpec(label: "Downloads", path: "~/Downloads", tag: "downloads"),
  ]

  // directory names mdfind looks up through the Spotlight index, tagged
  // with the project kind they imply.
  private static let projectMarkers: [(name: String, tag: String)] = [
    ("node_modules", "node"),
    ("target", "rust"),
    (".venv", "python"),
    ("venv", "python"),
  ]

  // a match living inside one of these is a nested dependency (e.g. a
  // package's own node_modules inside node_modules), filtered out so
  // only the top level project root is reported.
  private static let nestedJunkMarkers = ["/node_modules/", "/target/", "/.venv/", "/venv/"]

  private static let minReportBytes: Int64 = 1024 * 1024

  // each item is yielded as soon as its own probe finishes.
  static func scan() -> AsyncStream<StorageItem> {
    AsyncStream { continuation in
      let task = Task {
        primeProtectedFolderAccess()
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await scanGlobals(continuation) }
          group.addTask { await scanProjects(continuation) }
          group.addTask { await scanDocker(continuation) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // mdfind's own Spotlight query into a TCC protected folder returns
  // results silently filtered to whatever is already authorized - it
  // never itself surfaces the consent prompt. a direct top level listing
  // does surface that prompt, and once granted, mdfind's results for
  // that folder become complete for the rest of the process's lifetime.
  private static func primeProtectedFolderAccess() {
    for folder in ["Desktop", "Documents"] {
      _ = try? FileManager.default.contentsOfDirectory(
        atPath: NSHomeDirectory() + "/\(folder)")
    }
  }

  static func clear(_ item: StorageItem) -> Bool {
    let ok: Bool
    switch item.clear {
    case .removePath(let path):
      ok = (try? FileManager.default.removeItem(atPath: path)) != nil
    case .dockerRemoveImage(let id):
      ok = run("docker", ["rmi", "-f", id]) != nil
    case .dockerRemoveVolume(let name):
      ok = run("docker", ["volume", "rm", name]) != nil
    case .dockerPruneBuildCache:
      ok = run("docker", ["builder", "prune", "-af"]) != nil
    }
    if !ok {
      Log.network.warning("storage clear: failed for \(item.title)")
    }
    return ok
  }

  private static func scanGlobals(_ continuation: AsyncStream<StorageItem>.Continuation) async {
    await withTaskGroup(of: Void.self) { group in
      for spec in globals {
        group.addTask {
          let expanded = (spec.path as NSString).expandingTildeInPath
          guard let size = directorySize(expanded), size >= minReportBytes else { return }
          continuation.yield(
            StorageItem(
              id: expanded, title: spec.label, tag: spec.tag, sizeBytes: size,
              clear: .removePath(expanded)))
        }
      }
    }
  }

  private static func scanProjects(_ continuation: AsyncStream<StorageItem>.Continuation) async {
    await withTaskGroup(of: Void.self) { group in
      for marker in projectMarkers {
        group.addTask { await scanMarker(marker, continuation) }
      }
    }
  }

  private static func scanMarker(
    _ marker: (name: String, tag: String), _ continuation: AsyncStream<StorageItem>.Continuation
  ) async {
    let dirs = mdfindDirs(name: marker.name)
    await withTaskGroup(of: Void.self) { group in
      for dir in dirs {
        group.addTask {
          guard let size = directorySize(dir), size >= minReportBytes else { return }
          // the dir's own last component is always the marker name itself
          // (target/node_modules/venv), which the tag chip already says -
          // the project it belongs to is the useful part to show.
          let project = (dir as NSString).deletingLastPathComponent
          continuation.yield(
            StorageItem(id: dir, title: project, tag: marker.tag, sizeBytes: size, clear: .removePath(dir)))
        }
      }
    }
  }

  // reports one row per image so a specific bloated image is identifiable.
  private static func scanDocker(_ continuation: AsyncStream<StorageItem>.Continuation) async {
    if let imgOut = run(
      "docker", ["images", "--format", "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}"])
    {
      for line in imgOut.split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 4, let bytes = parseHumanSize(fields[3]), bytes >= minReportBytes
        else { continue }
        let name = fields[1] == "<none>" ? "dangling image \(fields[0])" : "\(fields[1]):\(fields[2])"
        continuation.yield(
          StorageItem(
            id: "docker:image:\(fields[0])", title: name, tag: "docker-image",
            sizeBytes: bytes, clear: .dockerRemoveImage(fields[0])))
      }
    }
    for volume in unusedDockerVolumes() {
      continuation.yield(
        StorageItem(
          id: "docker:volume:\(volume.name)", title: volume.name, tag: "docker-volume",
          sizeBytes: volume.sizeBytes, clear: .dockerRemoveVolume(volume.name)))
    }
    guard let dfOut = run("docker", ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"])
    else { return }
    for line in dfOut.split(separator: "\n") {
      let fields = line.split(separator: "\t").map(String.init)
      guard fields.count == 2, fields[0] == "Build Cache",
        let bytes = parseHumanSize(fields[1]), bytes >= minReportBytes
      else { continue }
      continuation.yield(
        StorageItem(
          id: "docker:buildcache", title: "build cache", tag: "docker-cache",
          sizeBytes: bytes, clear: .dockerPruneBuildCache))
    }
  }

  // only volumes with LINKS == 0 in the df -v table are reported.
  private static func unusedDockerVolumes() -> [(name: String, sizeBytes: Int64)] {
    guard let out = run("docker", ["system", "df", "-v"]) else { return [] }
    guard let startRange = out.range(of: "Local Volumes space usage:") else { return [] }
    let rest = out[startRange.upperBound...]
    var out2: [(name: String, sizeBytes: Int64)] = []
    for line in rest.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard fields.count == 3, fields[1] == "0", let bytes = parseHumanSize(fields[2]),
        bytes >= minReportBytes
      else { continue }
      out2.append((name: fields[0], sizeBytes: bytes))
    }
    return out2
  }

  // "12.54GB (45%)" -> drop the parenthetical, parse the leading number
  // and unit.
  private static func parseHumanSize(_ text: String) -> Int64? {
    let head = text.split(separator: " ").first.map(String.init) ?? text
    let digits = head.prefix { $0.isNumber || $0 == "." }
    guard let value = Double(digits) else { return nil }
    let unit = head.dropFirst(digits.count).uppercased()
    let multiplier: Double
    switch unit {
    case "KB": multiplier = 1_000
    case "MB": multiplier = 1_000_000
    case "GB": multiplier = 1_000_000_000
    case "TB": multiplier = 1_000_000_000_000
    default: multiplier = 1
    }
    return Int64(value * multiplier)
  }

  private static func mdfindDirs(name: String) -> [String] {
    guard
      let out = run(
        "/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "kMDItemFSName == '\(name)'"])
    else {
      Log.network.debug("mdfindDirs \(name): run() returned nil")
      return []
    }
    let rawLines = out.split(separator: "\n").map(String.init)
    Log.network.debug("mdfindDirs \(name): raw count=\(rawLines.count) first3=\(rawLines.prefix(3))")
    var isDir: ObjCBool = false
    let result = rawLines.filter { path in
      // anything under ~/Library is an app's own internals - a bundled
      // tool's node_modules, the pnpm store's own symlink farm, etc.
      // Downloads is reported as a single folder total, not per project.
      if path.contains("/Library/") || path.contains("/Downloads/") { return false }
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
      if !exists {
        Log.network.debug("mdfindDirs \(name): fileExists false for \(path)")
      }
      guard exists, isDir.boolValue else { return false }
      let parent = (path as NSString).deletingLastPathComponent
      return !nestedJunkMarkers.contains { parent.contains($0) }
    }
    Log.network.debug("mdfindDirs \(name): filtered count=\(result.count)")
    return result
  }

  private static func directorySize(_ path: String) -> Int64? {
    guard FileManager.default.fileExists(atPath: path) else {
      Log.network.debug("directorySize: fileExists false for \(path)")
      return nil
    }
    guard let out = run("/usr/bin/du", ["-sk", path]) else {
      Log.network.debug("directorySize: du run() returned nil for \(path)")
      return nil
    }
    let field = out.split(separator: "\t").first ?? out.split(separator: " ").first ?? ""
    guard let kb = Int64(field.trimmingCharacters(in: .whitespaces)) else {
      Log.network.debug("directorySize: unparsable du output '\(out)' for \(path)")
      return nil
    }
    return kb * 1024
  }

  private static func run(_ command: String, _ arguments: [String]) -> String? {
    let proc = Process()
    if command.hasPrefix("/") {
      proc.executableURL = URL(fileURLWithPath: command)
      proc.arguments = arguments
    } else {
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      proc.arguments = [command] + arguments
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = SystemPath.resolved
      proc.environment = env
    }
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      // a missing tool (e.g. no docker installed) means that source
      // contributes no rows.
      Log.network.warning("storage scan: \(command) launch failed: \(error)")
      return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }
}
