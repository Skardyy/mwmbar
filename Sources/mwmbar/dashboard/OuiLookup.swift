import Foundation

/// vendor name for a mac's oui prefix, from the ieee's own public MA-L
/// registry (bundled as Resources/oui.txt - a plain "PREFIX,Org Name" list,
/// ~40k entries). fully offline: no LAN mac address is ever sent to a
/// third party service for this.
enum OuiLookup {
  private static let table: [String: String] = {
    guard let url = Bundle.module.url(forResource: "oui", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      Log.network.warning("oui table: Resources/oui.txt not found in bundle")
      return [:]
    }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let commaIdx = line.firstIndex(of: ",") else { continue }
      let prefix = line[..<commaIdx]
      guard prefix.count == 6 else { continue }
      out[String(prefix)] = String(line[line.index(after: commaIdx)...])
    }
    return out
  }()

  static func vendor(for mac: String) -> String? {
    let prefix = mac.replacingOccurrences(of: ":", with: "").prefix(6).uppercased()
    return table[String(prefix)]
  }
}
