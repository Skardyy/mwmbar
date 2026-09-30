import Foundation
import os

/// Thin wrapper around os.Logger that also mirrors every line to stderr, so
/// `swift run` sees logs in the terminal without needing Console.app.
struct MwmLogger: Sendable {
  let category: String
  private let inner: Logger

  init(category: String) {
    self.category = category
    self.inner = Logger(subsystem: "wmwidget", category: category)
  }

  func debug(_ msg: String) {
    emit("debug", msg)
    inner.debug("\(msg, privacy: .public)")
  }
  func info(_ msg: String) {
    emit("info", msg)
    inner.info("\(msg, privacy: .public)")
  }
  func warning(_ msg: String) {
    emit("warn", msg)
    inner.warning("\(msg, privacy: .public)")
  }
  func error(_ msg: String) {
    emit("error", msg)
    inner.error("\(msg, privacy: .public)")
  }

  private func emit(_ level: String, _ msg: String) {
    let line = "[\(category)/\(level)] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

enum Log {
  static let bar = MwmLogger(category: "bar")
  static let source = MwmLogger(category: "source")
  static let socket = MwmLogger(category: "socket")
}
