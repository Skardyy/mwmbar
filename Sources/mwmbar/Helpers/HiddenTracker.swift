import AppKit
import ApplicationServices

/// Tracks which windows are currently minimized or belong to an app-hidden
/// application, keyed by CGWindowID as a String. Kept in sync via per-app AX
/// observers plus NSWorkspace hide/unhide notifications.
@MainActor
final class HiddenTracker {
  private(set) var hiddenIds: Set<String> = []
  var onChange: (() -> Void)?

  private var running = false
  private var observers: [pid_t: AXObserver] = [:]
  private var appWatchers: [NSObjectProtocol] = []

  func start() {
    if running { return }
    running = true
    reseed()
    let nc = NSWorkspace.shared.notificationCenter
    // observers registered with queue: .main run on the main thread, so
    // assumeIsolated is sound and avoids spawning a Task per notification.
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) { [weak self] n in
        let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { self?.handleAppEvent(pid: pid) }
      })
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] n in
        let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { self?.handleAppTerminated(pid: pid) }
      })
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reseed()
          self?.onChange?()
        }
      })
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reseed()
          self?.onChange?()
        }
      })
  }

  func stop() {
    if !running { return }
    running = false
    let nc = NSWorkspace.shared.notificationCenter
    for token in appWatchers { nc.removeObserver(token) }
    appWatchers.removeAll()
    for (_, obs) in observers {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
    observers.removeAll()
    hiddenIds.removeAll()
  }

  private func reseed() {
    var next: Set<String> = []
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
      installObserver(for: app.processIdentifier)
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
          == .success,
        let windows = value as? [AXUIElement]
      else { continue }
      let appHidden = app.isHidden
      for w in windows {
        guard let id = windowId(w) else { continue }
        if appHidden || isMinimized(w) { next.insert(String(id)) }
      }
    }
    if next != hiddenIds { hiddenIds = next }
  }

  private func handleAppEvent(pid: pid_t?) {
    guard let pid else { return }
    installObserver(for: pid)
    reseed()
    onChange?()
  }

  private func handleAppTerminated(pid: pid_t?) {
    guard let pid else { return }
    if let obs = observers.removeValue(forKey: pid) {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
    reseed()
    onChange?()
  }

  private func installObserver(for pid: pid_t) {
    if observers[pid] != nil { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let tracker = Unmanaged<HiddenTracker>.fromOpaque(refcon).takeUnretainedValue()
      Task { @MainActor in
        tracker.reseed()
        tracker.onChange?()
      }
    }
    let err = AXObserverCreate(pid, callback, &observer)
    guard err == .success, let observer else { return }
    let axApp = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for notif in [
      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
      kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
    ] {
      AXObserverAddNotification(observer, axApp, notif as CFString, refcon)
    }
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func windowId(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
  }

  private func isMinimized(_ el: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &value)
        == .success,
      let n = value as? NSNumber
    else { return false }
    return n.boolValue
  }
}

// private SPI: the public AX api exposes no way to map an AXUIElement back to
// a CGWindowID, which we need to correlate with aerospace's window ids.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
  _ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>
) -> AXError
