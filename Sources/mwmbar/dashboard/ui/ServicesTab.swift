import AppKit
import SwiftUI

enum ServiceKindFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case user = "User"
  case apple = "Apple"
  var id: String { rawValue }
}

@MainActor
final class ServicesTabState: ObservableObject {
  @Published var kindFilter: ServiceKindFilter = .all
}

struct ServicesTab: View {
  @Bindable var model: DashboardModel
  let store: ServiceStore
  let onAction: (ServiceAction) -> Void
  @Environment(ServiceGeneration.self) private var generation
  @StateObject private var state = ServicesTabState()

  var body: some View {
    // reading tick subscribes the view to snapshot commits.
    let _ = generation.tick
    let snapshot = store.snapshot()
    VStack(spacing: 8) {
      controls
      columnHeader
      list(services: snapshot.services)
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      HStack(spacing: 2) {
        ForEach(ServiceKindFilter.allCases) { opt in
          FilterChip(
            label: opt.rawValue,
            selected: state.kindFilter == opt,
            action: { state.kindFilter = opt })
        }
      }
      TextField("Filter by label", text: $model.serviceSearch)
        .textFieldStyle(.roundedBorder)
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 4) {
      Text("Label")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("PID")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 60, alignment: .trailing)
      Text("Exit")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 50, alignment: .trailing)
    }
    .padding(.horizontal, 8)
  }

  private func list(services: [ServiceInfo]) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(filtered(services)) { svc in
          ServiceRow(service: svc, onAction: onAction)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func filtered(_ services: [ServiceInfo]) -> [ServiceInfo] {
    let base: [ServiceInfo]
    switch state.kindFilter {
    case .all: base = services
    case .user: base = services.filter { $0.kind == .user }
    case .apple: base = services.filter { $0.kind == .apple }
    }
    let searched =
      model.serviceSearch.isEmpty
      ? base
      : base.filter { $0.label.localizedCaseInsensitiveContains(model.serviceSearch) }
    return searched.sorted { a, b in
      if a.isRunning != b.isRunning { return a.isRunning }
      if a.kind != b.kind { return Self.kindRank(a.kind) < Self.kindRank(b.kind) }
      return a.label.localizedCompare(b.label) == .orderedAscending
    }
  }

  private static func kindRank(_ k: ServiceInfo.Kind) -> Int {
    switch k {
    case .user: return 0
    case .apple: return 1
    }
  }
}

private struct ServiceRow: View {
  let service: ServiceInfo
  let onAction: (ServiceAction) -> Void
  @StateObject private var hover = RowHover()

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(service.isRunning ? Color.green : Color.secondary.opacity(0.4))
        .frame(width: 7, height: 7)
      Text(service.label)
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(service.pid.map(String.init) ?? "-")
        .frame(width: 60, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(service.isRunning ? .primary : .secondary)
      Text(service.lastExitCode.map(String.init) ?? "-")
        .frame(width: 50, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(exitTint)
    }
    .font(.system(size: 12))
    .padding(.vertical, 5)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hover.value ? Color.primary.opacity(0.08) : .clear)
    )
    .onHover { hover.value = $0 }
    .contextMenu {
      Button("Start") { onAction(.start(service.label)) }
      Button("Stop") { onAction(.stop(service.label)) }
      Button("Restart") { onAction(.restart(service.label)) }
    }
  }

  private var exitTint: Color {
    guard let code = service.lastExitCode else { return .secondary }
    return code == 0 ? .secondary : .red
  }
}

@MainActor
private final class RowHover: ObservableObject {
  @Published var value = false
}
