import Foundation

struct Workspace: Identifiable, Hashable, Sendable {
  let id: String
  var windows: [Window]
}
