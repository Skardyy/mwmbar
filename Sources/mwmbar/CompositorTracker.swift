import AppKit
import ApplicationServices

/// authoritative view of currently alive normal layer windows system wide:
/// their owning pid, bundle id, title, and whether they are hidden or
/// miniaturized. populated from CGWindowListCopyWindowInfo and kept current
/// with AX notifications and NSWorkspace hide/launch events.
@MainActor
final class CompositorTracker {
  struct WindowInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleId: String?
    let name: String?
  }

  private(set) var live: [String: WindowInfo] = [:]
  private(set) var hidden: Set<String> = []
  /// window id of the topmost normal layer window owned by the frontmost app,
  /// or nil when nothing has focus.
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
    // use the prompting variant so the binary gets registered in the
    // Accessibility list; the plain AXIsProcessTrusted only reads state
    // and never surfaces the binary to the user as a toggle.
    let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
    let trusted = AXIsProcessTrustedWithOptions(opts)
    Log.bar.info("CompositorTracker start trusted=\(trusted)")
    seedObservers()
    rescan()
    seedHidden()
    installWorkspaceObservers()
    refreshFocus(pid: nil)
  }

  /// install an AX observer on every running regular app, including ones with
  /// no current windows, so AXWindowCreated on a later open fires into a live
  /// listener (Finder and other system apps start with zero windows).
  private func seedObservers() {
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
      installObserver(for: app.processIdentifier)
    }
  }
}

extension CompositorTracker {
  fileprivate func installWorkspaceObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    observeApp(nc, NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in
      self?.handleAppLaunched(pid: pid)
    }
    observeApp(nc, NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
      self?.handleAppTerminated(pid: pid)
    }
    observeApp(nc, NSWorkspace.didHideApplicationNotification) { [weak self] pid in
      self?.setAppHidden(pid: pid, hidden: true)
    }
    observeApp(nc, NSWorkspace.didUnhideApplicationNotification) { [weak self] pid in
      self?.setAppHidden(pid: pid, hidden: false)
    }
    observeApp(nc, NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
      self?.refreshFocus(pid: pid)
    }
  }

  private func observeApp(
    _ nc: NotificationCenter, _ name: NSNotification.Name,
    _ handler: @escaping @Sendable @MainActor (pid_t?) -> Void
  ) {
    appWatchers.append(
      nc.addObserver(forName: name, object: nil, queue: .main) { n in
        let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { handler(pid) }
      })
  }
}

extension CompositorTracker {
  func setHidden(_ value: Set<String>) { hidden = value }
  func writeFocusedWindowId(_ value: String?) { focusedWindowId = value }
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

  func rescanAll() { scheduleRescan(pid: nil) }

  /// pass nil pid for a full rescan (startup / app join / app terminate).
  /// pass a pid for a targeted rescan of just that app's windows.
  private func scheduleRescan(pid: pid_t? = nil) {
    if let pid { pendingPids.insert(pid) } else { pendingPids.removeAll() }
    if scanPending { return }
    scanPending = true
    let fullScan = pid == nil
    // 50ms debounce coalesces AX bursts (quit, mass create) into one scan.
    PerfTrace.incr("tracker.scheduleRescan")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.scanPending = false
        let span = PerfTrace.begin(fullScan ? "tracker.rescan.full" : "tracker.rescan.pid")
        let prevLive = self.live
        let prevHidden = self.hidden
        if fullScan || self.pendingPids.isEmpty {
          self.rescan()
        } else {
          let pids = self.pendingPids
          self.pendingPids.removeAll()
          for p in pids { self.rescanPid(p) }
        }
        PerfTrace.end(span, detail: "live=\(self.live.count)")
        if self.live != prevLive || self.hidden != prevHidden {
          let added = Set(self.live.keys).subtracting(prevLive.keys)
          let removed = Set(prevLive.keys).subtracting(self.live.keys)
          if !added.isEmpty || !removed.isEmpty {
            Log.bar.debug(
              "live delta +\(added.sorted().joined(separator: ",")) "
                + "-\(removed.sorted().joined(separator: ","))")
          }
          PerfTrace.incr("tracker.onChange")
          self.onChange?()
        }
        // live set grew: a new window appeared and likely belongs to the
        // frontmost app, so recompute focus now that CGWindow lists it.
        if self.live.count > prevLive.count { self.refreshFocus(pid: nil) }
      }
    }
  }

  /// refresh live entries for a single pid by filtering CGWindowListCopyWindowInfo
  /// to that owner; prunes ids no longer present.
  private func rescanPid(_ pid: pid_t) {
    guard
      let app = NSRunningApplication(processIdentifier: pid),
      app.activationPolicy == .regular
    else {
      live = live.filter { $0.value.pid != pid }
      hidden = hidden.filter { live[$0] != nil }
      return
    }
    let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return }
    var seen: Set<String> = []
    let axWindows = axWindowIds(for: pid)
    for dict in list {
      guard
        let number = dict[kCGWindowNumber as String] as? CGWindowID,
        let ownerPid = dict[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid,
        let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
        axWindows.contains(number)
      else { continue }
      let sid = String(number)
      seen.insert(sid)
      let name = dict[kCGWindowName as String] as? String ?? app.localizedName
      live[sid] = WindowInfo(pid: pid, bundleId: app.bundleIdentifier, name: name)
    }
    for (sid, info) in live where info.pid == pid && !seen.contains(sid) {
      live.removeValue(forKey: sid)
      hidden.remove(sid)
    }
  }

  /// rebuild `live` from a single CGWindowListCopyWindowInfo pass over every
  /// normal layer window system wide, and prune `hidden` to the surviving ids.
  private func rescan() {
    var nextLive: [String: WindowInfo] = [:]
    let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return }
    var axCache: [pid_t: Set<CGWindowID>] = [:]
    for dict in list {
      guard
        let number = dict[kCGWindowNumber as String] as? CGWindowID,
        let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
        let layer = dict[kCGWindowLayer as String] as? Int,
        layer == 0,
        let app = NSRunningApplication(processIdentifier: pid),
        app.activationPolicy == .regular
      else { continue }
      let axWindows = axCache[pid] ?? axWindowIds(for: pid)
      axCache[pid] = axWindows
      guard axWindows.contains(number) else { continue }
      installObserver(for: pid)
      let sid = String(number)
      let name = dict[kCGWindowName as String] as? String ?? app.localizedName
      nextLive[sid] = WindowInfo(pid: pid, bundleId: app.bundleIdentifier, name: name)
    }
    live = nextLive
    hidden = hidden.filter { live[$0] != nil }
  }

  /// a CGWindow entry counts as a real window only if the owning app's AX
  /// kAXWindows list contains a matching CGWindowID. filters out popover
  /// surfaces, toolbars, shadow layers etc that CG reports at layer 0.
  private func axWindowIds(for pid: pid_t) -> Set<CGWindowID> {
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return [] }
    var ids: Set<CGWindowID> = []
    for w in windows {
      var wid: CGWindowID = 0
      if _AXUIElementGetWindow(w, &wid) == .success { ids.insert(wid) }
    }
    return ids
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

  fileprivate func handleAxEvent(name: String, pid: pid_t?, elementWid: String?) {
    switch name {
    case kAXFocusedWindowChangedNotification:
      refreshFocus(pid: pid)
    case kAXWindowMiniaturizedNotification:
      if let id = elementWid { markHidden(id, true) }
    case kAXWindowDeminiaturizedNotification:
      if let id = elementWid { markHidden(id, false) }
    case kAXWindowCreatedNotification:
      // CGWindow lags newly created windows by a few ms; rescan + refocus so
      // a freshly spawned window shows up and claims focus immediately.
      scheduleRescan(pid: pid)
      refreshFocus(pid: pid)
    default:
      scheduleRescan(pid: pid)
    }
  }

  private func installObserver(for pid: pid_t) {
    if observers[pid] != nil { return }
    var observer: AXObserver?
    let err = AXObserverCreate(pid, compositorAxCallback, &observer)
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
  func windowId(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
  }

  func isMinimized(_ el: AXUIElement) -> Bool {
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

// private SPI: the public AX api exposes no way to map an AXUIElement back
// to a CGWindowID, so bind _AXUIElementGetWindow directly.
private func compositorAxCallback(
  _ observer: AXObserver,
  _ element: AXUIElement,
  _ notif: CFString,
  _ refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let tracker = Unmanaged<CompositorTracker>.fromOpaque(refcon).takeUnretainedValue()
  let name = notif as String
  var elementPid: pid_t = 0
  let pidOk = AXUIElementGetPid(element, &elementPid) == .success
  let scanPid = pidOk ? elementPid : nil
  // read windowId on the AX thread while the element is still valid; the
  // destroyed element may be stale by the time the MainActor hop runs.
  var wid: CGWindowID = 0
  let elementWid: String? =
    _AXUIElementGetWindow(element, &wid) == .success ? String(wid) : nil
  Task { @MainActor in
    Log.bar.debug("AX event \(name) pid=\(scanPid.map(String.init) ?? "?")")
    tracker.handleAxEvent(name: name, pid: scanPid, elementWid: elementWid)
  }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>
) -> AXError
