import AppKit
import SwiftUI

struct SystemLoad: Equatable {
  var cpuBusy: Double = 0
  var memUsedBytes: UInt64 = 0
  var memTotalBytes: UInt64 = 1
  var coreCount: Int = 1
  var memUsedFraction: Double { Double(memUsedBytes) / Double(memTotalBytes) }
}

enum ProcFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case user = "User"
  case system = "System"
  var id: String { rawValue }
}

enum SortColumn { case name, cpu, memory }

@MainActor
final class CpuDashboardModel: ObservableObject {
  @Published var load = SystemLoad()
  @Published var procs: [ProcInfo] = []
  @Published var filter: ProcFilter = .all
  @Published var sortColumn: SortColumn = .cpu
  @Published var sortAsc = false
  @Published var search = ""

  // computed every render. ProcessSampler returns ~500 items at 1.5 s;
  // filter + sort + search on that is well under a frame budget, so no
  // memoisation is worth the staleness risk.
  var filtered: [ProcInfo] {
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

struct CpuDashboard: View {
  @ObservedObject var model: CpuDashboardModel
  @ObservedObject var caffeine: CaffeineController
  let onKill: (pid_t, Bool) -> Void

  var body: some View {
    VStack(spacing: 10) {
      header
      Divider()
      controls
      Divider()
      columnHeader
      list
    }
    .padding(10)
    .frame(
      minWidth: 460, idealWidth: 520, maxWidth: 760,
      minHeight: 420, idealHeight: 520, maxHeight: 820)
  }

  private var header: some View {
    HStack(spacing: 18) {
      MetricGauge(
        title: "CPU", percent: model.load.cpuBusy,
        subtitle: String(format: "%.0f%%", model.load.cpuBusy),
        tint: cpuTint)
      MetricGauge(
        title: "Memory", percent: model.load.memUsedFraction * 100,
        subtitle: memLabel, tint: memTint)
      Spacer()
      CaffeineButton(caffeine: caffeine)
    }
    .padding(.horizontal, 4)
  }

  private var controls: some View {
    HStack(spacing: 8) {
      FilterSegment(model: model)
      TextField("Filter by name", text: $model.search)
        .textFieldStyle(.roundedBorder)
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 4) {
      SortHeader(label: "Process", column: .name, model: model, alignment: .leading)
        .frame(maxWidth: .infinity)
      SortHeader(label: "CPU", column: .cpu, model: model, alignment: .trailing)
        .frame(width: 72)
      SortHeader(label: "Mem", column: .memory, model: model, alignment: .trailing)
        .frame(width: 88)
      Text("User")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 96, alignment: .leading)
        .padding(.leading, 6)
    }
    .padding(.horizontal, 4)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        // 300 row cap. a healthy mac has 400 to 700 pids and rendering all
        // of them inside a popover drops scroll fps noticeably. sort order
        // puts the interesting rows (cpu or mem) at the top anyway.
        ForEach(model.filtered.prefix(300)) { proc in
          ProcRow(proc: proc, onKill: onKill)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var memLabel: String {
    let gb = Double(model.load.memUsedBytes) / 1_073_741_824
    let total = Double(model.load.memTotalBytes) / 1_073_741_824
    return String(format: "%.1f / %.0f GB", gb, total)
  }

  private var cpuTint: Color {
    model.load.cpuBusy > 80 ? .red : model.load.cpuBusy > 50 ? .orange : .green
  }

  private var memTint: Color {
    let f = model.load.memUsedFraction
    return f > 0.9 ? .red : f > 0.75 ? .orange : .blue
  }
}

private struct FilterSegment: View {
  @ObservedObject var model: CpuDashboardModel

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ProcFilter.allCases) { option in
        FilterChip(
          label: option.rawValue,
          selected: model.filter == option,
          action: { model.filter = option })
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.06)))
  }
}

@MainActor
private final class ChipHover: ObservableObject {
  @Published var value = false
}

private struct FilterChip: View {
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
private final class HeaderHover: ObservableObject {
  @Published var value = false
}

private struct SortHeader: View {
  let label: String
  let column: SortColumn
  @ObservedObject var model: CpuDashboardModel
  @StateObject private var hover = HeaderHover()
  // caller controls alignment via trailing / leading. the chevron slot is
  // always reserved so the label does not jump when active toggles.
  var alignment: HorizontalAlignment = .leading

  var body: some View {
    Button {
      model.toggleSort(column)
    } label: {
      HStack(spacing: 3) {
        if alignment == .trailing { Spacer(minLength: 0) }
        Text(label)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(active ? Color.primary : .secondary)
        Image(systemName: model.sortAsc ? "chevron.up" : "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
          .opacity(active ? 1 : 0)
        if alignment == .leading { Spacer(minLength: 0) }
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(hover.value ? Color.primary.opacity(0.08) : .clear))
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
  }

  private var active: Bool { model.sortColumn == column }
}

@MainActor
private final class CaffeineHover: ObservableObject {
  @Published var value = false
}

private struct CaffeineButton: View {
  @ObservedObject var caffeine: CaffeineController
  @StateObject private var hover = CaffeineHover()

  var body: some View {
    Button {
      caffeine.toggle()
    } label: {
      VStack(spacing: 2) {
        Image(systemName: caffeine.active ? "cup.and.saucer.fill" : "cup.and.saucer")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(iconTint)
        Text(caffeine.active ? "On" : "Off")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(iconTint.opacity(0.85))
      }
      .frame(width: 56, height: 56)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(backgroundTint)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            caffeine.active ? Self.activeInk.opacity(0.25) : Color.white.opacity(0.08),
            lineWidth: 1)
      )
      .scaleEffect(hover.value ? 1.04 : 1.0)
      .animation(.easeOut(duration: 0.12), value: hover.value)
      .animation(.easeOut(duration: 0.18), value: caffeine.active)
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
    .help(
      caffeine.active
        ? "Keep awake ON. Lid closed still forces clamshell sleep."
        : "Click to prevent sleep (caffeinate -dis)")
  }

  // active = warm amber (coffee tone, Material 3 "tertiary container" vibe).
  // amber on dark text reads better than green on white.
  private static let activeFill = Color(red: 0.98, green: 0.74, blue: 0.28)
  private static let activeInk = Color(red: 0.22, green: 0.14, blue: 0.03)

  private var iconTint: Color {
    caffeine.active ? Self.activeInk : .primary
  }

  private var backgroundTint: Color {
    if caffeine.active {
      return Self.activeFill.opacity(hover.value ? 1.0 : 0.92)
    }
    return hover.value ? Color.primary.opacity(0.14) : Color.primary.opacity(0.07)
  }
}

private struct MetricGauge: View {
  let title: String
  let percent: Double
  let subtitle: String
  let tint: Color

  var body: some View {
    VStack(spacing: 2) {
      ZStack {
        Circle()
          .stroke(Color.gray.opacity(0.22), lineWidth: 5)
        Circle()
          .trim(from: 0, to: max(0, min(1, percent / 100)))
          .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          // SwiftUI draws the trim starting at 3 o clock. rotate so 0%
          // sits at 12 and the arc sweeps clockwise like a dial.
          .rotationEffect(.degrees(-90))
          .animation(.spring(response: 0.5, dampingFraction: 0.85), value: percent)
        Text(String(format: "%.0f%%", percent))
          .font(.system(size: 13, weight: .semibold))
          .monospacedDigit()
      }
      .frame(width: 54, height: 54)
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(subtitle)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .frame(width: 90)
  }
}

@MainActor
private final class RowHover: ObservableObject {
  @Published var value = false
}

private struct ProcRow: View {
  let proc: ProcInfo
  let onKill: (pid_t, Bool) -> Void
  @StateObject private var hover = RowHover()

  var body: some View {
    HStack(spacing: 4) {
      Text(proc.name)
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(String(format: "%.1f", proc.cpuPercent))
        .frame(width: 72, alignment: .trailing)
        .monospacedDigit()
      Text(memString(proc.rssBytes))
        .frame(width: 88, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text(proc.user)
        .frame(width: 96, alignment: .leading)
        .padding(.leading, 6)
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 12))
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(hover.value ? Color.accentColor.opacity(0.14) : .clear)
    .onHover { hover.value = $0 }
    .contextMenu {
      // SIGTERM first lets the process clean up; SIGKILL is the hammer
      // for anything hung. destructive role gives the red styling.
      Button("Terminate (SIGTERM)") { onKill(proc.id, false) }
      Button("Force Kill (SIGKILL)", role: .destructive) { onKill(proc.id, true) }
    }
  }

  private func memString(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
  }
}
