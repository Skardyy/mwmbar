import Foundation

struct Monitor: Identifiable, Hashable, Sendable {
  let id: String
  let nsScreenName: String
  var workspaces: [Workspace]
  var focusedWorkspaceId: String?
}
