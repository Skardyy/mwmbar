import Foundation

struct Monitor: Identifiable, Hashable, Sendable {
  let nsScreenName: String
  var workspaces: [Workspace]
  var focusedWorkspaceId: String?

  var id: String { nsScreenName }
}
