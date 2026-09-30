import Foundation

struct Workspace: Identifiable, Hashable {
  let id: String
  var isVisible: Bool
  /// true for stack/accordion layouts where spatial sorting would misrepresent z-order
  var preserveOrder: Bool
  var windows: [Window]
}
