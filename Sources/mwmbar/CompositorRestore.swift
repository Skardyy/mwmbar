import AppKit
import ApplicationServices

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

  /// terminate the owning app when it holds only this window (one window per
  /// pid apps lose only the clicked window; one window multi window apps
  /// quit outright, same as cmd+Q). AX close otherwise, so multi window apps
  /// lose only the clicked window.
  func close(id: String) {
    guard let info = live[id], let widInt = UInt32(id) else {
      Log.bar.warning("close \(id): unknown to compositor or non numeric id.")
      return
    }
    let axWindowCount = countAXWindows(pid: info.pid)
    if axWindowCount <= 1 {
      Log.bar.debug("close \(id): sole AX window of pid=\(info.pid), terminate app.")
      NSRunningApplication(processIdentifier: info.pid)?.terminate()
      return
    }
    if pressAXClose(windowId: CGWindowID(widInt), pid: info.pid) {
      Log.bar.debug("close \(id): AX press ok pid=\(info.pid), \(axWindowCount) windows.")
    } else {
      Log.bar.warning("close \(id): AX miss on multi window pid, no fallback.")
    }
  }

  private func countAXWindows(pid: pid_t) -> Int {
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return 0 }
    return windows.count
  }

  private func pressAXClose(windowId: CGWindowID, pid: pid_t) -> Bool {
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return false }
    for w in windows {
      var wid: CGWindowID = 0
      guard _AXUIElementGetWindow(w, &wid) == .success, wid == windowId else { continue }
      var btn: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &btn) == .success,
        let btn
      else { return false }
      let closeBtn = unsafeDowncast(btn, to: AXUIElement.self)
      AXUIElementPerformAction(closeBtn, kAXPressAction as CFString)
      return true
    }
    return false
  }

}
