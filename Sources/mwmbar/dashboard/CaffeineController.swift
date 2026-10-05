import Darwin
import Foundation

/// manages a child `caffeinate` process. toggling off terminates it so the
/// kernel power assertion drops. no sudo required; this is the OS supported
/// way to inhibit idle / display / system sleep while the Mac is in use.
///
/// caveat: with the laptop lid closed macOS forces clamshell sleep regardless
/// of these assertions unless the Mac is on power with an external display
/// and USB device attached (official Apple clamshell behavior) or
/// `sudo pmset -a disablesleep 1` was applied globally.
@MainActor
final class CaffeineController: ObservableObject {
  @Published private(set) var active = false
  private var process: Process?

  func toggle() {
    if active { stop() } else { start() }
  }

  func start() {
    guard process == nil else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // -d prevent display sleep, -i prevent idle, -s prevent system sleep on
    // AC power. -w self-exits when the parent pid dies, closing the leak if
    // mwmbar crashes without a chance to clean up.
    p.arguments = ["-d", "-i", "-s", "-w", String(ProcessInfo.processInfo.processIdentifier)]
    // route child stdio to /dev/null. if mwmbar was launched by launchd with
    // closed descriptors, a caffeinate write would raise SIGPIPE on the
    // inherited handle and kill us.
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
      try p.run()
      process = p
      active = true
    } catch {
      Log.bar.warning("caffeinate launch failed: \(error)")
    }
  }

  func stop() {
    process?.terminate()
    process = nil
    active = false
  }

  deinit {
    process?.terminate()
  }
}
