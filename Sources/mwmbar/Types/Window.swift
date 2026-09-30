import Foundation

struct Window: Identifiable, Hashable, Sendable {
  let id: String
  let bundleId: String
  let name: String
  var isHidden: Bool = false
}
