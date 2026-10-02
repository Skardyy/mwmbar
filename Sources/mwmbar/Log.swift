import Foundation
import os

/// wrapper around os.Logger. all output is gated by LogConfig.level; default
/// is .off so no stderr writes, no string interpolation cost, and no unified
/// logging daemon hop. enable per run via MWMBAR_LOG=debug | info | warn |
/// error. the unified log can also be tailed live when enabled via:
/// `log stream --predicate 'subsystem == "wmwidget"'`.
struct MwmLogger: Sendable {
  let category: String
  private let inner: Logger

  init(category: String) {
    self.category = category
    self.inner = Logger(subsystem: "wmwidget", category: category)
  }

  func debug(_ msg: @autoclosure () -> String) {
    guard LogConfig.level >= .debug else { return }
    let s = msg()
    emit("debug", s)
    inner.debug("\(s, privacy: .public)")
  }
  func info(_ msg: @autoclosure () -> String) {
    guard LogConfig.level >= .info else { return }
    let s = msg()
    emit("info", s)
    inner.info("\(s, privacy: .public)")
  }
  func warning(_ msg: @autoclosure () -> String) {
    guard LogConfig.level >= .warn else { return }
    let s = msg()
    emit("warn", s)
    inner.warning("\(s, privacy: .public)")
  }
  func error(_ msg: @autoclosure () -> String) {
    guard LogConfig.level >= .error else { return }
    let s = msg()
    emit("error", s)
    inner.error("\(s, privacy: .public)")
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
  // default off. @autoclosure in MwmLogger guards both the string build and
  // the Logger subsystem call so the hot path is a single level compare.
  static let level: LogLevel = {
    switch ProcessInfo.processInfo.environment["MWMBAR_LOG"]?.lowercased() {
    case "off", nil: return .off
    case "error": return .error
    case "warn", "warning": return .warn
    case "info": return .info
    case "debug": return .debug
    default: return .off
    }
  }()
}

enum Log {
  static let bar = MwmLogger(category: "bar")
  static let source = MwmLogger(category: "source")
  static let socket = MwmLogger(category: "socket")
}
