import Foundation
import os

/// wrapper around os.Logger. os.Logger writes to unified logging always;
/// the stderr mirror is filtered by MWMBAR_LOG (off | error | warn | info |
/// debug, default debug). unified logs remain readable via
/// `log stream --predicate 'subsystem == "wmwidget"'` even with mirror off.
struct MwmLogger: Sendable {
  let category: String
  private let inner: Logger

  init(category: String) {
    self.category = category
    self.inner = Logger(subsystem: "wmwidget", category: category)
  }

  func debug(_ msg: String) {
    if LogConfig.stderrLevel >= .debug { emit("debug", msg) }
    inner.debug("\(msg, privacy: .public)")
  }
  func info(_ msg: String) {
    if LogConfig.stderrLevel >= .info { emit("info", msg) }
    inner.info("\(msg, privacy: .public)")
  }
  func warning(_ msg: String) {
    if LogConfig.stderrLevel >= .warn { emit("warn", msg) }
    inner.warning("\(msg, privacy: .public)")
  }
  func error(_ msg: String) {
    if LogConfig.stderrLevel >= .error { emit("error", msg) }
    inner.error("\(msg, privacy: .public)")
  }

  private func emit(_ level: String, _ msg: String) {
    let line = "[\(category)/\(level)] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

enum LogLevel: Int, Comparable {
  case off = 0
  case error, warn, info, debug
  static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

enum LogConfig {
  static let stderrLevel: LogLevel = {
    switch ProcessInfo.processInfo.environment["MWMBAR_LOG"]?.lowercased() {
    case "off": return .off
    case "error": return .error
    case "warn", "warning": return .warn
    case "info": return .info
    case "debug", nil: return .debug
    default: return .debug
    }
  }()
}

enum Log {
  static let bar = MwmLogger(category: "bar")
  static let source = MwmLogger(category: "source")
  static let socket = MwmLogger(category: "socket")
}
