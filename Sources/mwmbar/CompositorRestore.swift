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
}
