import AppKit
import ScreenCaptureKit

/// composite preview of a set of windows. ScreenCaptureKit renders the given
/// windows against the current display and returns a single CGImage.
@MainActor
final class PeekService {
  struct CacheEntry {
    let ids: Set<CGWindowID>
    let image: NSImage
    let timestamp: Date
  }

  /// how long a cached composite is considered fresh. covers in window
  /// content changes (text input, animations) that the compositor cannot
  /// detect, without re rendering on every hover.
  private let ttl: TimeInterval = 2
  private var cache: [String: CacheEntry] = [:]
  private var permissionChecked = false

  /// trigger the Screen Recording permission prompt if not granted.
  func ensurePermission() {
    if permissionChecked { return }
    permissionChecked = true
    if CGPreflightScreenCaptureAccess() { return }
    Log.bar.warning("Screen Recording permission missing. prompting.")
    _ = CGRequestScreenCaptureAccess()
  }

  func capture(windowIds: [CGWindowID], completion: @escaping @MainActor (NSImage?) -> Void) {
    let key = cacheKey(windowIds)
    if let hit = cache[key], Date().timeIntervalSince(hit.timestamp) < ttl {
      completion(hit.image)
      return
    }
    guard !windowIds.isEmpty else {
      completion(nil)
      return
    }
    let idSet = Set(windowIds)
    Task { [weak self] in
      guard let self else { return }
      let image = await self.captureAsync(ids: idSet)
      await MainActor.run {
        if let image {
          self.cache[key] = CacheEntry(ids: idSet, image: image, timestamp: Date())
        }
        completion(image)
      }
    }
  }

  func invalidateAll() { cache.removeAll() }

  func invalidate(windowId: CGWindowID) {
    cache = cache.filter { !$0.value.ids.contains(windowId) }
  }

  private func cacheKey(_ ids: [CGWindowID]) -> String {
    ids.sorted().map(String.init).joined(separator: ",")
  }

  private nonisolated func captureAsync(ids: Set<CGWindowID>) async -> NSImage? {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      let targets = content.windows.filter { ids.contains($0.windowID) }
      if targets.isEmpty { return nil }
      let images = await parallelCapture(targets: targets)
      guard !images.isEmpty else { return nil }
      return composite(images)
    } catch {
      Log.bar.warning("peek SCK capture failed: \(String(describing: error))")
      return nil
    }
  }
}

/// SCWindow is not Sendable so a plain closure capture is rejected; the
/// WindowServer backing object is immutable snapshot data in practice.
private struct WindowBox: @unchecked Sendable {
  let value: SCWindow
}

/// run per window captures concurrently. SCScreenshotManager calls block
/// until the WindowServer round trips, so N serial captures take Nx; parallel
/// captures overlap and finish in roughly the slowest single call's time.
private func parallelCapture(targets: [SCWindow]) async -> [CGImage] {
  await withTaskGroup(of: (Int, CGImage?).self, returning: [CGImage].self) { group in
    for (i, w) in targets.enumerated() {
      let boxed = WindowBox(value: w)
      group.addTask { @Sendable in (i, await captureWindow(boxed.value)) }
    }
    var buf: [(Int, CGImage?)] = []
    for await r in group { buf.append(r) }
    return buf.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
  }
}

private func captureWindow(_ w: SCWindow) async -> CGImage? {
  let filter = SCContentFilter(desktopIndependentWindow: w)
  let cfg = SCStreamConfiguration()
  let scale = CGFloat(filter.pointPixelScale)
  cfg.width = Int(max(1, filter.contentRect.width * scale))
  cfg.height = Int(max(1, filter.contentRect.height * scale))
  cfg.showsCursor = false
  return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}

/// side by side tiling. per window SCK capture returns an image sized to the
/// window; the composite width is the sum and height the max.
private func composite(_ images: [CGImage]) -> NSImage? {
  let gap = 12
  let totalW = images.reduce(0) { $0 + $1.width } + gap * max(0, images.count - 1)
  let totalH = images.map(\.height).max() ?? 0
  guard totalW > 0, totalH > 0 else { return nil }
  let space = CGColorSpaceCreateDeviceRGB()
  guard
    let ctx = CGContext(
      data: nil, width: totalW, height: totalH, bitsPerComponent: 8,
      bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  var x = 0
  for img in images {
    let y = (totalH - img.height) / 2
    ctx.draw(img, in: CGRect(x: x, y: y, width: img.width, height: img.height))
    x += img.width + gap
  }
  guard let out = ctx.makeImage() else { return nil }
  return NSImage(cgImage: out, size: NSSize(width: totalW, height: totalH))
}
