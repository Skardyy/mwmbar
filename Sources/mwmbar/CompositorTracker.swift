import AppKit
import ApplicationServices

/// macOS native window lifecycle authority. sits between the WM source and the
/// bar UI: knows which windows are actually alive right now, their owning pid,
/// bundle id, and title, and which are hidden or miniaturized. we trust the
/// compositor over the WM so WM lag (aerospace not yet noticing a closed
/// window, for example) does not leak into the UI.
@MainActor
final class CompositorTracker {
  struct WindowInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleId: String?
    let name: String?
  }

  private(set) var live: [String: WindowInfo] = [:]
  private(set) var hidden: Set<String> = []
  var onChange: (() -> Void)?

  private var running = false
  private var observers: [pid_t: AXObserver] = [:]
  private var appWatchers: [NSObjectProtocol] = []
  private var loggedFailedPids: Set<pid_t> = []
  private var scanPending = false

  func start() {
    if running { return }
    running = true
    Log.bar.info("CompositorTracker start trusted=\(AXIsProcessTrusted())")
    rescan()
    let nc = NSWorkspace.shared.notificationCenter
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) { [weak self] n in
        let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { self?.handleAppLaunched(pid: pid) }
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
        MainActor.assumeIsolated { self?.scheduleRescan() }
      })
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleRescan() }
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
    live.removeAll()
    hidden.removeAll()
  }

  private func scheduleRescan() {
    if scanPending { return }
    scanPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.scanPending = false
        self.rescan()
        self.onChange?()
      }
    }
  }

  private func rescan() {
    var nextLive: [String: WindowInfo] = [:]
    var nextHidden: Set<String> = []
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
      let pid = app.processIdentifier
      installObserver(for: pid)
      let axApp = AXUIElementCreateApplication(pid)
      var value: CFTypeRef?
      let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
      guard err == .success, let windows = value as? [AXUIElement] else {
        if err != .success, !loggedFailedPids.contains(pid) {
          loggedFailedPids.insert(pid)
          let bid = app.bundleIdentifier ?? "?"
          Log.bar.warning(
            "AX kAXWindows failed pid=\(pid) err=\(err.rawValue) app=\(bid). check permission.")
        }
        continue
      }
      let bundleId = app.bundleIdentifier
      let appHidden = app.isHidden
      for w in windows {
        guard let id = windowId(w) else { continue }
        let sid = String(id)
        nextLive[sid] = WindowInfo(pid: pid, bundleId: bundleId, name: title(w))
        if appHidden || isMinimized(w) { nextHidden.insert(sid) }
      }
    }
    live = nextLive
    hidden = nextHidden
  }

  private func handleAppLaunched(pid: pid_t?) {
    guard let pid else {
      Log.bar.error("didLaunchApplication notification missing pid. skipping rescan.")
      return
    }
    installObserver(for: pid)
    scheduleRescan()
  }

  private func handleAppTerminated(pid: pid_t?) {
    guard let pid else {
      Log.bar.error("didTerminateApplication notification missing pid. skipping rescan.")
      return
    }
    if let obs = observers.removeValue(forKey: pid) {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
    loggedFailedPids.remove(pid)
    scheduleRescan()
  }

  private func installObserver(for pid: pid_t) {
    if observers[pid] != nil { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let tracker = Unmanaged<CompositorTracker>.fromOpaque(refcon).takeUnretainedValue()
      Task { @MainActor in tracker.scheduleRescan() }
    }
    let err = AXObserverCreate(pid, callback, &observer)
    guard err == .success, let observer else {
      if !loggedFailedPids.contains(pid) {
        loggedFailedPids.insert(pid)
        Log.bar.warning(
          "AXObserverCreate pid=\(pid) err=\(err.rawValue). check Accessibility permission.")
      }
      return
    }
    let axApp = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for notif in [
      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
      kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
      kAXTitleChangedNotification,
    ] {
      let addErr = AXObserverAddNotification(observer, axApp, notif as CFString, refcon)
      if addErr != .success {
        Log.bar.error(
          "AXObserverAddNotification failed pid=\(pid) notif=\(notif) err=\(addErr.rawValue).")
      }
    }
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func windowId(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
  }

  private func title(_ el: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  private func isMinimized(_ el: AXUIElement) -> Bool {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &value)
    if err != .success {
      Log.bar.warning(
        "AX kAXMinimized failed err=\(err.rawValue). isHidden may be inaccurate.")
      return false
    }
    return (value as? NSNumber)?.boolValue ?? false
  }
}

// public AX api exposes no way to map an AXUIElement back to a CGWindowID, so
// we bind the private symbol directly.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
  _ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>
) -> AXError
