import Foundation

struct AerospaceMonitorRow: Decodable {
  let id: Int
  let name: String
  private enum CodingKeys: String, CodingKey {
    case id = "monitor-id"
    case name = "monitor-name"
  }
}

struct AerospaceWorkspaceRow: Decodable {
  let id: String
  let monitorId: Int
  let isVisible: Bool
  let rootLayout: String
  private enum CodingKeys: String, CodingKey {
    case id = "workspace"
    case monitorId = "monitor-id"
    case isVisible = "workspace-is-visible"
    case rootLayout = "workspace-root-container-layout"
  }
}

struct AerospaceWindowRow: Decodable {
  let id: Int
  let appName: String
  let bundleId: String
  let workspace: String
  let monitorId: Int
  private enum CodingKeys: String, CodingKey {
    case id = "window-id"
    case appName = "app-name"
    case bundleId = "app-bundle-id"
    case workspace
    case monitorId = "monitor-id"
  }
}
