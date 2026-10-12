import AppKit
import ApplicationServices

/// public window shape consumed by Invalidator.
struct CompositorWindow: Equatable, Sendable {
  let wid: CGWindowID
  let pid: pid_t
  let bundleId: String?
  let hidden: Bool
  let isFocused: Bool
}

/// per pid lifecycle wrapper.
@MainActor
final class CompositorApp {
  let pid: pid_t
  let nsApp: NSRunningApplication

  struct Callbacks {
    let windowAppeared: (CGWindowID, Bool) -> Void
    let windowDisappeared: (CGWindowID) -> Void
    let windowHiddenChanged: (CGWindowID, Bool) -> Void
    let focusChanged: (CGWindowID?) -> Void
    let isActiveChanged: () -> Void
    let appHiddenChanged: (Bool) -> Void
  }

  private var axApp: AXUIElement
  private var observer: AXObserver?
  private var isFinishedLaunchingKvo: NSKeyValueObservation?
  private var isActiveKvo: NSKeyValueObservation?
  private var isHiddenKvo: NSKeyValueObservation?
  private var subscribedDestroys: Set<CGWindowID> = []
  private let callbacks: Callbacks

  init(nsApp: NSRunningApplication, callbacks: Callbacks) {
    self.pid = nsApp.processIdentifier
    self.nsApp = nsApp
    self.callbacks = callbacks
    self.axApp = AXUIElementCreateApplication(nsApp.processIdentifier)

    isActiveKvo = nsApp.observe(\.isActive, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.callbacks.isActiveChanged() }
    }
    isHiddenKvo = nsApp.observe(\.isHidden, options: [.new]) { [weak self] app, _ in
      let hidden = app.isHidden
      MainActor.assumeIsolated { self?.callbacks.appHiddenChanged(hidden) }
    }

    if nsApp.isFinishedLaunching {
      installAx()
    } else {
      isFinishedLaunchingKvo = nsApp.observe(\.isFinishedLaunching, options: [.new]) {
        [weak self] app, _ in
        guard app.isFinishedLaunching else { return }
        MainActor.assumeIsolated {
          self?.isFinishedLaunchingKvo?.invalidate()
          self?.isFinishedLaunchingKvo = nil
          self?.installAx()
        }
      }
    }
  }

  func tearDown() {
    isFinishedLaunchingKvo?.invalidate()
    isActiveKvo?.invalidate()
    isHiddenKvo?.invalidate()
    isFinishedLaunchingKvo = nil
    isActiveKvo = nil
    isHiddenKvo = nil
    if let obs = observer {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
      observer = nil
    }
  }

  // AX observer and per window destroy subscriptions.
  private func installAx() {
    var obs: AXObserver?
    guard AXObserverCreate(pid, compositorAxCallback, &obs) == .success, let obs
    else { return }
    observer = obs
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    let appRefcon = Unmanaged.passUnretained(self).toOpaque()
    for notif in [
      kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ] {
      AXObserverAddNotification(obs, axApp, notif as CFString, appRefcon)
    }
    refreshWindows()
    callbacks.focusChanged(axFocusedWid(axApp: axApp))
  }

  fileprivate func handleAxEvent(name: String, elementWid: CGWindowID?) {
    switch name {
    case kAXWindowCreatedNotification:
      refreshWindows()
      callbacks.focusChanged(axFocusedWid(axApp: axApp))
    case kAXFocusedWindowChangedNotification:
      callbacks.focusChanged(elementWid ?? axFocusedWid(axApp: axApp))
    case kAXWindowMiniaturizedNotification:
      if let wid = elementWid { callbacks.windowHiddenChanged(wid, true) }
    case kAXWindowDeminiaturizedNotification:
      if let wid = elementWid { callbacks.windowHiddenChanged(wid, false) }
    default:
      break
    }
  }

  fileprivate func handleWindowDestroyed(wid: CGWindowID) {
    subscribedDestroys.remove(wid)
    callbacks.windowDisappeared(wid)
  }

  // emits windowAppeared and subscribes destroy for AX windows we have not
  // seen yet. idempotent: the Compositor dict write is overwrite safe and
  // the destroy subscription set guards against duplicate subscriptions.
  private func refreshWindows() {
    for (wid, element) in axWindowPairs(axApp: axApp)
    where !subscribedDestroys.contains(wid) {
      callbacks.windowAppeared(wid, axMinimized(element))
      subscribeDestroy(element: element, wid: wid)
    }
  }

  private func subscribeDestroy(element: AXUIElement, wid: CGWindowID) {
    guard let obs = observer else { return }
    let packed = (UInt(pid) << 32) | UInt(wid)
    let refcon = UnsafeMutableRawPointer(bitPattern: packed)
    if AXObserverAddNotification(
      obs, element, kAXUIElementDestroyedNotification as CFString, refcon) == .success
    {
      subscribedDestroys.insert(wid)
    }
  }

}

private func axWindowPairs(axApp: AXUIElement) -> [(CGWindowID, AXUIElement)] {
  var value: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
    let list = value as? [AXUIElement]
  else { return [] }
  var out: [(CGWindowID, AXUIElement)] = []
  for element in list {
    var wid: CGWindowID = 0
    if _AXUIElementGetWindow(element, &wid) == .success { out.append((wid, element)) }
  }
  return out
}

private func axFocusedWid(axApp: AXUIElement) -> CGWindowID? {
  var value: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
      == .success,
    let element = value
  else { return nil }
  var wid: CGWindowID = 0
  let el = unsafeDowncast(element, to: AXUIElement.self)
  return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
}

private func axMinimized(_ element: AXUIElement) -> Bool {
  var value: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success
  else { return false }
  return (value as? NSNumber)?.boolValue ?? false
}

@MainActor
final class Compositor {
  private(set) var windows: [CGWindowID: CompositorWindow] = [:]
  var focusedWid: CGWindowID? {
    guard let activePid = apps.values.first(where: { $0.nsApp.isActive })?.pid
    else { return nil }
    return windows.first { $0.value.pid == activePid && $0.value.isFocused }?.key
  }
  var onChange: (() -> Void)?

  private var apps: [pid_t: CompositorApp] = [:]
  private var runningAppsKvo: NSKeyValueObservation?

  func start() {
    sharedCompositor = Unmanaged.passUnretained(self)
    let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(opts)
    for nsApp in NSWorkspace.shared.runningApplications
    where nsApp.activationPolicy == .regular {
      attachApp(nsApp)
    }
    runningAppsKvo = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        var seen: Set<pid_t> = []
        for nsApp in NSWorkspace.shared.runningApplications
        where nsApp.activationPolicy == .regular {
          seen.insert(nsApp.processIdentifier)
          if self.apps[nsApp.processIdentifier] == nil { self.attachApp(nsApp) }
        }
        for pid in self.apps.keys where !seen.contains(pid) { self.detachApp(pid: pid) }
      }
    }
  }

  func stop() {
    runningAppsKvo?.invalidate()
    runningAppsKvo = nil
    for (_, app) in apps { app.tearDown() }
    apps.removeAll()
    windows.removeAll()
    sharedCompositor = nil
  }

  func unhide(wid: CGWindowID) {
    guard let info = windows[wid] else { return }
    let axApp = AXUIElementCreateApplication(info.pid)
    var list: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
      let elements = list as? [AXUIElement]
    else { return }
    for element in elements {
      var found: CGWindowID = 0
      guard _AXUIElementGetWindow(element, &found) == .success, found == wid else { continue }
      AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
      AXUIElementPerformAction(element, kAXRaiseAction as CFString)
      return
    }
  }

  func close(wid: CGWindowID) {
    guard let info = windows[wid] else { return }
    let sibling = windows.values.contains { $0.pid == info.pid && $0.wid != wid }
    if !sibling {
      NSRunningApplication(processIdentifier: info.pid)?.terminate()
      return
    }
    let axApp = AXUIElementCreateApplication(info.pid)
    var list: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
      let elements = list as? [AXUIElement]
    else { return }
    for element in elements {
      var found: CGWindowID = 0
      guard _AXUIElementGetWindow(element, &found) == .success, found == wid else { continue }
      var btn: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &btn)
          == .success, let btn
      else { return }
      AXUIElementPerformAction(
        unsafeDowncast(btn, to: AXUIElement.self), kAXPressAction as CFString)
      return
    }
  }

  fileprivate func dispatchDestroyed(pid: pid_t, wid: CGWindowID) {
    apps[pid]?.handleWindowDestroyed(wid: wid)
  }

  // callbacks capture pid and bundleId so later events never have to walk
  // state to find the owner. closures mutate `windows` directly, then fire
  // the single onChange closure handed to the Invalidator.
  private func attachApp(_ nsApp: NSRunningApplication) {
    let pid = nsApp.processIdentifier
    let bundleId = nsApp.bundleIdentifier
    let app = CompositorApp(
      nsApp: nsApp,
      callbacks: .init(
        windowAppeared: { [weak self] wid, hidden in
          guard let self else { return }
          self.windows[wid] = CompositorWindow(
            wid: wid, pid: pid, bundleId: bundleId, hidden: hidden, isFocused: false)
          self.onChange?()
        },
        windowDisappeared: { [weak self] wid in
          guard let self, self.windows.removeValue(forKey: wid) != nil else { return }
          self.onChange?()
        },
        windowHiddenChanged: { [weak self] wid, hidden in
          guard let self, let w = self.windows[wid], w.hidden != hidden else { return }
          self.windows[wid] = CompositorWindow(
            wid: w.wid, pid: w.pid, bundleId: w.bundleId, hidden: hidden, isFocused: w.isFocused)
          self.onChange?()
        },
        focusChanged: { [weak self] newWid in
          guard let self else { return }
          var changed = false
          for (sid, w) in self.windows where w.pid == pid {
            let shouldFocus = sid == newWid
            if w.isFocused != shouldFocus {
              self.windows[sid] = CompositorWindow(
                wid: w.wid, pid: w.pid, bundleId: w.bundleId, hidden: w.hidden,
                isFocused: shouldFocus)
              changed = true
            }
          }
          if changed { self.onChange?() }
        },
        isActiveChanged: { [weak self] in
          self?.onChange?()
        },
        appHiddenChanged: { [weak self] appHidden in
          guard let self else { return }
          var changed = false
          for (sid, w) in self.windows where w.pid == pid {
            if w.hidden != appHidden {
              self.windows[sid] = CompositorWindow(
                wid: w.wid, pid: w.pid, bundleId: w.bundleId, hidden: appHidden,
                isFocused: w.isFocused)
              changed = true
            }
          }
          if changed { self.onChange?() }
        }))
    apps[pid] = app
    onChange?()
  }

  private func detachApp(pid: pid_t) {
    apps.removeValue(forKey: pid)?.tearDown()
    let before = windows.count
    windows = windows.filter { $0.value.pid != pid }
    if windows.count != before { onChange?() }
  }

}

nonisolated(unsafe) var sharedCompositor: Unmanaged<Compositor>?

// file scope AX callback. app level events route to the CompositorApp pointer
// stashed in refcon; destroy events use a packed (pid<<32)|wid refcon so the
// handler can route to the right compositor without dereferencing the dying
// element on the hop to main.
private let compositorAxCallback: AXObserverCallback = {
  (_, element, notif, refcon) in
  let name = notif as String
  if name == kAXUIElementDestroyedNotification {
    guard let refcon else { return }
    let packed = UInt(bitPattern: refcon)
    let pid = pid_t(packed >> 32)
    let wid = CGWindowID(packed & 0xFFFF_FFFF)
    guard let compositorRef = sharedCompositor else { return }
    Task { @MainActor in compositorRef.takeUnretainedValue().dispatchDestroyed(pid: pid, wid: wid) }
    return
  }
  guard let refcon else { return }
  var elementWid: CGWindowID = 0
  let widOk = _AXUIElementGetWindow(element, &elementWid) == .success
  let widOpt: CGWindowID? = widOk ? elementWid : nil
  let appRef = Unmanaged<CompositorApp>.fromOpaque(refcon)
  Task { @MainActor in
    appRef.takeUnretainedValue().handleAxEvent(name: name, elementWid: widOpt)
  }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>
) -> AXError
