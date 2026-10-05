import AppKit
import Observation
import SwiftUI

enum DashboardTab: String, CaseIterable, Identifiable {
  case system = "System"
  case services = "Services"
  case network = "Network"
  var id: String { rawValue }
}

@MainActor
@Observable
final class DashboardModel {
  var tab: DashboardTab = .system
  // system tab
  var filter: ProcFilter = .all
  var sortColumn: SortColumn = .cpu
  var sortAsc = false
  var search = ""
  // services tab
  var serviceSearch = ""

  func filtered(_ procs: [ProcInfo]) -> [ProcInfo] {
    let base: [ProcInfo]
    switch filter {
    case .all: base = procs
    case .user: base = procs.filter { !$0.isSystem }
    case .system: base = procs.filter { $0.isSystem }
    }
    let searched =
      search.isEmpty
      ? base
      : base.filter { $0.name.localizedCaseInsensitiveContains(search) }
    let ordered: [ProcInfo]
    switch sortColumn {
    case .name:
      ordered = searched.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    case .cpu:
      ordered = searched.sorted { $0.cpuPercent > $1.cpuPercent }
    case .memory:
      ordered = searched.sorted { $0.rssBytes > $1.rssBytes }
    }
    return sortAsc ? ordered.reversed() : ordered
  }

  // tap same column flips direction; tap new column resets to descending.
  // descending is the useful default for cpu + memory (busy processes at
  // the top); name picks it up too for consistency.
  func toggleSort(_ col: SortColumn) {
    if sortColumn == col {
      sortAsc.toggle()
    } else {
      sortColumn = col
      sortAsc = false
    }
  }
}

struct Dashboard: View {
  @Bindable var model: DashboardModel
  @ObservedObject var caffeine: CaffeineController
  @ObservedObject var peekPref: PeekPreference
  let store: SystemStore
  let serviceStore: ServiceStore
  let networkStore: NetworkStore
  let onKill: (pid_t, Bool) -> Void
  let onServiceAction: (ServiceAction) -> Void
  let onNetworkScan: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      TabPicker(selection: $model.tab)
      Divider()
      Group {
        switch model.tab {
        case .system:
          SystemTab(
            model: model, caffeine: caffeine, peekPref: peekPref, store: store, onKill: onKill)
        case .services:
          ServicesTab(model: model, store: serviceStore, onAction: onServiceAction)
        case .network:
          NetworkTab(store: networkStore, onScan: onNetworkScan)
        }
      }
    }
    .padding(10)
    .frame(
      minWidth: 460, idealWidth: 520, maxWidth: 760,
      minHeight: 420, idealHeight: 520, maxHeight: 820)
  }
}

struct TabPicker: View {
  @Binding var selection: DashboardTab

  var body: some View {
    HStack(spacing: 2) {
      ForEach(DashboardTab.allCases) { tab in
        FilterChip(
          label: tab.rawValue,
          selected: selection == tab,
          action: { selection = tab })
      }
      Spacer()
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04)))
  }
}

struct FilterChip: View {
  let label: String
  let selected: Bool
  let action: () -> Void
  @StateObject private var hover = ChipHover()

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(selected ? Color.primary : .secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
        )
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
    .animation(.easeOut(duration: 0.12), value: hover.value)
    .animation(.easeOut(duration: 0.12), value: selected)
  }

  private var fill: Color {
    if selected { return Color.primary.opacity(0.14) }
    return hover.value ? Color.primary.opacity(0.08) : .clear
  }
}

@MainActor
final class ChipHover: ObservableObject {
  @Published var value = false
}
