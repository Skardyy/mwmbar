import AppKit

/// per bundle icon cache. prefers NSRunningApplication.icon (already in
/// memory, no disk hit) and falls back to NSWorkspace.icon(forFile:) only
/// when the app is not currently running. bounded LRU prevents the cache
/// from growing without bound across long sessions.
@MainActor
final class IconCache {
  static let shared = IconCache()
  private var cache: [String: NSImage] = [:]
  private var order: [String] = []
  private let maxEntries = 128

  func icon(for bundleId: String) -> NSImage? {
    if let hit = cache[bundleId] { return hit }
    if let img = runningIcon(for: bundleId) ?? bundleIcon(for: bundleId) {
      insert(bundleId: bundleId, img: img)
      return img
    }
    Log.bar.info("no installed app for bundle \(bundleId)")
    return nil
  }

  private func insert(bundleId: String, img: NSImage) {
    if cache.count >= maxEntries, let oldest = order.first {
      order.removeFirst()
      cache.removeValue(forKey: oldest)
    }
    cache[bundleId] = img
    order.append(bundleId)
  }

  private func runningIcon(for bundleId: String) -> NSImage? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
      .lazy.compactMap(\.icon).first
  }

  private func bundleIcon(for bundleId: String) -> NSImage? {
    guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
    else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
  }
}
