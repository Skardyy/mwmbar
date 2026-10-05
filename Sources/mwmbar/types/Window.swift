import Foundation

struct Window: Identifiable, Hashable, Sendable {
  let id: String
  var bundleId: String
  var name: String
  var isHidden: Bool = false
}
