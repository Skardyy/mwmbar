import Foundation

struct Window: Identifiable, Hashable {
  let id: String
  let bundleId: String
  let name: String
  var isHidden: Bool
}
