import AppKit

enum WMKind: String, CaseIterable, Identifiable {
  case aerospace
  case none
  var id: String { rawValue }

  var label: String {
    switch self {
    case .aerospace: return "Aerospace"
    case .none: return "None"
    }
  }
}

@MainActor
final class WMPreference: ObservableObject {
  private static let key = "wm.kind"

  @Published var kind: WMKind {
    didSet { UserDefaults.standard.set(kind.rawValue, forKey: Self.key) }
  }

  init() {
    UserDefaults.standard.register(defaults: [Self.key: WMKind.aerospace.rawValue])
    let raw = UserDefaults.standard.string(forKey: Self.key) ?? WMKind.aerospace.rawValue
    self.kind = WMKind(rawValue: raw) ?? .aerospace
  }
}
