import AppKit

@MainActor
final class IconCache {
  static let shared = IconCache()
  private var cache: [String: NSImage] = [:]

  func icon(for bundleId: String) -> NSImage? {
    if let hit = cache[bundleId] { return hit }
    guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
    else {
      Log.bar.info("no installed app for bundle \(bundleId)")
      return nil
    }
    let img = NSWorkspace.shared.icon(forFile: path)
    cache[bundleId] = img
    return img
  }
}
