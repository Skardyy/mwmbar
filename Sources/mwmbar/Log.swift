import os

enum Log {
  static let bar = Logger(subsystem: "wmwidget", category: "bar")
  static let source = Logger(subsystem: "wmwidget", category: "source")
  static let socket = Logger(subsystem: "wmwidget", category: "socket")
}
