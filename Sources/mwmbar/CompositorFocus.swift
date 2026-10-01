import AppKit
import ApplicationServices

extension CompositorTracker {
  /// focus is the topmost normal-layer window owned by the frontmost app.
  /// CGWindowListCopyWindowInfo returns windows in z order so the first match
  /// wins. no AX, no readiness delay, no retry.
  func refreshFocus(pid: pid_t? = nil) {
    let target = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let target else {
      setFocused(nil)
      return
    }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else {
      setFocused(nil)
      return
    }
    for dict in list {
      guard
        let ownerPid = dict[kCGWindowOwnerPID as String] as? pid_t, ownerPid == target,
        let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
        let number = dict[kCGWindowNumber as String] as? CGWindowID
      else { continue }
      setFocused(String(number))
      return
    }
    setFocused(nil)
  }

  /// one off AX sweep at startup to pick up windows that are already minimized
  /// or belong to app hidden processes. after this, hidden is maintained
  /// purely by AX notifications and NSWorkspace hide/unhide events.
  func seedHidden() {
    var next: Set<String> = []
    for (sid, info) in live {
      let axApp = AXUIElementCreateApplication(info.pid)
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
          == .success,
        let windows = value as? [AXUIElement]
      else { continue }
      if NSRunningApplication(processIdentifier: info.pid)?.isHidden == true {
        next.insert(sid)
        continue
      }
      for w in windows where windowId(w).map(String.init) == sid {
        if isMinimized(w) { next.insert(sid) }
        break
      }
    }
    if next != hidden {
      setHidden(next)
      onChange?()
    }
  }

  func setAppHidden(pid: pid_t?, hidden value: Bool) {
    guard let pid else { return }
    var changed = false
    var next = hidden
    for (sid, info) in live where info.pid == pid {
      if value {
        if next.insert(sid).inserted { changed = true }
      } else {
        if next.remove(sid) != nil { changed = true }
      }
    }
    if changed {
      setHidden(next)
      onChange?()
    }
  }

  func markHidden(_ id: String, _ value: Bool) {
    var next = hidden
    let changed: Bool
    if value {
      changed = next.insert(id).inserted
    } else {
      changed = next.remove(id) != nil
    }
    if changed {
      setHidden(next)
      onChange?()
    }
  }

  func setFocused(_ id: String?) {
    if focusedWindowId == id { return }
    writeFocusedWindowId(id)
    onFocusChange?()
  }
}
