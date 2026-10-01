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
  /// the window id with system focus, driven by NSWorkspace frontmost app plus
  /// per app kAXFocusedWindowChanged. nil when nothing has focus.
  private(set) var focusedWindowId: String?
  var onChange: (() -> Void)?
  var onFocusChange: (() -> Void)?

  private var running = false
  private var observers: [pid_t: AXObserver] = [:]
  private var appWatchers: [NSObjectProtocol] = []
  private var loggedFailedPids: Set<pid_t> = []
  private var pendingPids: Set<pid_t> = []
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
    appWatchers.append(
      nc.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] n in
        let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { self?.refreshFocus(pid: pid) }
      })
    refreshFocus(pid: nil)
  }
}

extension CompositorTracker {
  /// pass pid when the caller already knows the active app (notification
  /// userInfo gives the authoritative pid; NSWorkspace.frontmostApplication
  /// can lag at the moment didActivate fires). newly launched apps return nil
  /// here because their AX tree is not fully built; retry 200ms later once.
  func refreshFocus(pid: pid_t? = nil, retry: Bool = true) {
    let target = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let target else {
      setFocused(nil)
      return
    }
    let axApp = AXUIElementCreateApplication(target)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
      axApp, kAXFocusedWindowAttribute as CFString, &value)
    guard err == .success, let value else {
      setFocused(nil)
      if retry {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          MainActor.assumeIsolated { self?.refreshFocus(pid: target, retry: false) }
        }
      }
      return
    }
    // AXUIElement is a CF type; `as?` on CFTypeRef bridges wrong. downcast directly.
    let axWindow = unsafeDowncast(value, to: AXUIElement.self)
    setFocused(windowId(axWindow).map(String.init))
  }

  fileprivate func setFocused(_ id: String?) {
    if focusedWindowId == id { return }
    focusedWindowId = id
    onFocusChange?()
  }

}

extension CompositorTracker {
  /// unminimize and raise a window by its CGWindowID. walks the owning pid's
  /// AX windows because AX offers no direct id to AXUIElement lookup.
  func restore(id: String) {
    guard let info = live[id] else {
      Log.bar.warning("restore \(id): unknown to compositor. bar and tracker desynced.")
      return
    }
    guard let widInt = UInt32(id) else {
      Log.bar.error("restore \(id): id not numeric.")
      return
    }
    let target = CGWindowID(widInt)
    let axApp = AXUIElementCreateApplication(info.pid)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let windows = value as? [AXUIElement] else {
      Log.bar.warning("restore \(id): AX kAXWindows failed pid=\(info.pid) err=\(err.rawValue).")
      return
    }
    for w in windows {
      var wid: CGWindowID = 0
      if _AXUIElementGetWindow(w, &wid) == .success, wid == target {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        return
      }
    }
    Log.bar.warning("restore \(id): window not found in pid=\(info.pid) AX list.")
  }
}

extension CompositorTracker {
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

  /// pass nil pid for a full rescan (startup / app join / app terminate).
  /// pass a pid for a targeted rescan of just that app's windows.
  private func scheduleRescan(pid: pid_t? = nil) {
    if let pid { pendingPids.insert(pid) } else { pendingPids.removeAll() }
    if scanPending { return }
    scanPending = true
    let fullScan = pid == nil
    // 50ms debounce coalesces AX bursts (quit, mass create) into one scan.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.scanPending = false
        let prevLive = self.live
        let prevHidden = self.hidden
        if fullScan || self.pendingPids.isEmpty {
          self.rescan()
        } else {
          let pids = self.pendingPids
          self.pendingPids.removeAll()
          for p in pids { self.rescanPid(p) }
        }
        if self.live != prevLive || self.hidden != prevHidden {
          self.onChange?()
        }
      }
    }
  }

  /// rescan a single app's windows and merge into the live/hidden sets.
  /// used for AX destroy/create/miniaturize bursts so we avoid iterating
  /// every process when only one app changed.
  private func rescanPid(_ pid: pid_t) {
    guard
      let app = NSRunningApplication(processIdentifier: pid),
      app.activationPolicy == .regular
    else {
      live = live.filter { $0.value.pid != pid }
      hidden = hidden.filter { live[$0] != nil }
      return
    }
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    var seen: Set<String> = []
    if err == .success, let windows = value as? [AXUIElement] {
      let bundleId = app.bundleIdentifier
      let appHidden = app.isHidden
      for w in windows {
        guard let id = windowId(w) else { continue }
        let sid = String(id)
        seen.insert(sid)
        live[sid] = WindowInfo(pid: pid, bundleId: bundleId, name: title(w))
        if appHidden || isMinimized(w) { hidden.insert(sid) } else { hidden.remove(sid) }
      }
    } else if !loggedFailedPids.contains(pid), err != .success {
      loggedFailedPids.insert(pid)
      let bid = app.bundleIdentifier ?? "?"
      Log.bar.warning(
        "AX kAXWindows failed pid=\(pid) err=\(err.rawValue) app=\(bid). check permission.")
    }
    // evict stale ids for this pid: anything attributed to pid but missing from the fresh AX scan.
    for (sid, info) in live where info.pid == pid && !seen.contains(sid) {
      live.removeValue(forKey: sid)
      hidden.remove(sid)
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
    scheduleRescan(pid: pid)
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
    scheduleRescan(pid: pid)
  }

  private func installObserver(for pid: pid_t) {
    if observers[pid] != nil { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notif, refcon in
      guard let refcon else { return }
      let tracker = Unmanaged<CompositorTracker>.fromOpaque(refcon).takeUnretainedValue()
      let name = notif as String
      var elementPid: pid_t = 0
      let pidOk = AXUIElementGetPid(element, &elementPid) == .success
      let scanPid = pidOk ? elementPid : nil
      let isFocusEvent = name == (kAXFocusedWindowChangedNotification as String)
      Task { @MainActor in
        Log.bar.debug("AX event \(name) pid=\(scanPid.map(String.init) ?? "?")")
        if isFocusEvent {
          tracker.refreshFocus(pid: scanPid)
        } else {
          tracker.scheduleRescan(pid: scanPid)
        }
      }
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
      kAXFocusedWindowChangedNotification,
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

}

extension CompositorTracker {
  fileprivate func windowId(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
  }

  fileprivate func title(_ el: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  fileprivate func isMinimized(_ el: AXUIElement) -> Bool {
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
