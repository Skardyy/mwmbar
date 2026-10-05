import AppKit
import Atomics
import Observation
import SwiftUI

struct SystemLoad: Equatable, Sendable {
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

/// immutable sample snapshot; written off main, read on main.
struct CpuSnapshot: Sendable {
  var load: SystemLoad = SystemLoad()
  var procs: [ProcInfo] = []
}

/// observation trigger bumped after every snapshot commit so views can
/// resubscribe.
@MainActor
@Observable
final class CpuGeneration {
  var tick: UInt64 = 0
}

/// reference wrapped snapshot so the atomic swap works on a single word.
private final class CpuSnapshotBox: @unchecked Sendable {
  let value: CpuSnapshot
  init(_ value: CpuSnapshot) { self.value = value }
}

/// atomic snapshot store. writers passRetained a new box and exchange;
/// readers (main only) load lock free. old boxes are released on main so
/// no reader can dereference a freed pointer in the same runloop cycle.
final class CpuStore: @unchecked Sendable {
  let generation: CpuGeneration
  private let snapshotPtr: ManagedAtomic<UInt>

  @MainActor init() {
    self.generation = CpuGeneration()
    let box = CpuSnapshotBox(CpuSnapshot())
    let raw = Unmanaged.passRetained(box).toOpaque()
    self.snapshotPtr = ManagedAtomic<UInt>(UInt(bitPattern: raw))
  }

  deinit {
    let raw = snapshotPtr.load(ordering: .relaxed)
    if let ptr = UnsafeRawPointer(bitPattern: raw) {
      Unmanaged<CpuSnapshotBox>.fromOpaque(ptr).release()
    }
  }

  @MainActor func snapshot() -> CpuSnapshot {
    let raw = snapshotPtr.load(ordering: .acquiring)
    let ptr = UnsafeRawPointer(bitPattern: raw)!
    return Unmanaged<CpuSnapshotBox>.fromOpaque(ptr).takeUnretainedValue().value
  }

  func commit(_ snap: CpuSnapshot) {
    let newBox = CpuSnapshotBox(snap)
    let newRaw = Unmanaged.passRetained(newBox).toOpaque()
    let oldRawInt = snapshotPtr.exchange(
      UInt(bitPattern: newRaw), ordering: .acquiringAndReleasing)
    let gen = generation
    Task { @MainActor in
      if let oldPtr = UnsafeRawPointer(bitPattern: oldRawInt) {
        Unmanaged<CpuSnapshotBox>.fromOpaque(oldPtr).release()
      }
      gen.tick &+= 1
    }
  }
}

@MainActor
@Observable
final class CpuDashboardModel {
  var filter: ProcFilter = .all
  var sortColumn: SortColumn = .cpu
  var sortAsc = false
  var search = ""

  /// filter + sort + search is cheap on 500 ish items so it runs every
  /// render; memoising it against the latest snapshot would stale faster
  /// than it would save frame time.
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

struct CpuDashboard: View {
  @Bindable var model: CpuDashboardModel
  @ObservedObject var caffeine: CaffeineController
  @ObservedObject var peekPref: PeekPreference
  let store: CpuStore
  @Environment(CpuGeneration.self) private var generation
  let onKill: (pid_t, Bool) -> Void

  var body: some View {
    // reading tick subscribes the view to snapshot commits.
    let _ = generation.tick
    let snapshot = store.snapshot()
    VStack(spacing: 10) {
      header(load: snapshot.load)
      Divider()
      controls
      Divider()
      columnHeader
      list(procs: snapshot.procs)
    }
    .padding(10)
    .frame(
      minWidth: 460, idealWidth: 520, maxWidth: 760,
      minHeight: 420, idealHeight: 520, maxHeight: 820)
  }

  private func header(load: SystemLoad) -> some View {
    HStack(spacing: 18) {
      MetricGauge(
        title: "CPU", percent: load.cpuBusy,
        subtitle: String(format: "%.0f%%", load.cpuBusy),
        tint: cpuTint(load))
      MetricGauge(
        title: "Memory", percent: load.memUsedFraction * 100,
        subtitle: memLabel(load), tint: memTint(load))
      Spacer()
      PeekButton(pref: peekPref)
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
      // icon column slot keeps the Process label aligned with the row text,
      // not the row icon.
      Color.clear.frame(width: 20, height: 1)
      SortHeader(label: "Process", column: .name, model: model, alignment: .leading)
        .frame(maxWidth: .infinity)
      SortHeader(label: "CPU", column: .cpu, model: model, alignment: .trailing)
        .frame(width: 60)
      SortHeader(label: "Mem", column: .memory, model: model, alignment: .trailing)
        .frame(width: 72)
    }
    .padding(.horizontal, 4)
  }

  private func list(procs: [ProcInfo]) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        // 300 row cap. a healthy mac has 400 to 700 pids and rendering all
        // of them inside a popover drops scroll fps noticeably. sort order
        // puts the interesting rows (cpu or mem) at the top anyway.
        ForEach(model.filtered(procs).prefix(300)) { proc in
          ProcRow(proc: proc, onKill: onKill)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func memLabel(_ load: SystemLoad) -> String {
    let gb = Double(load.memUsedBytes) / 1_073_741_824
    let total = Double(load.memTotalBytes) / 1_073_741_824
    return String(format: "%.1f / %.0f GB", gb, total)
  }

  private func cpuTint(_ load: SystemLoad) -> Color {
    load.cpuBusy > 80 ? .red : load.cpuBusy > 50 ? .orange : .green
  }

  private func memTint(_ load: SystemLoad) -> Color {
    let f = load.memUsedFraction
    return f > 0.9 ? .red : f > 0.75 ? .orange : .blue
  }
}

private struct FilterSegment: View {
  @Bindable var model: CpuDashboardModel

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
  @Bindable var model: CpuDashboardModel
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
private final class ToggleTileHover: ObservableObject {
  @Published var value = false
}

/// square tile button for a boolean toggle; caller supplies icons, colors,
/// title, and tooltip strings.
private struct ToggleTile: View {
  let title: String
  let isActive: Bool
  let iconOn: String
  let iconOff: String
  let activeFill: Color
  let activeInk: Color
  let helpOn: String
  let helpOff: String
  let action: () -> Void

  @StateObject private var hover = ToggleTileHover()

  var body: some View {
    VStack(spacing: 4) {
      Button(action: action) {
        VStack(spacing: 2) {
          Image(systemName: isActive ? iconOn : iconOff)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(iconTint)
          Text(isActive ? "On" : "Off")
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
              isActive ? activeInk.opacity(0.25) : Color.white.opacity(0.08),
              lineWidth: 1)
        )
        .scaleEffect(hover.value ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hover.value)
        .animation(.easeOut(duration: 0.18), value: isActive)
      }
      .buttonStyle(.plain)
      .onHover { hover.value = $0 }
      .help(isActive ? helpOn : helpOff)
      Text(title)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private var iconTint: Color {
    isActive ? activeInk : .primary
  }

  private var backgroundTint: Color {
    if isActive {
      return activeFill.opacity(hover.value ? 1.0 : 0.92)
    }
    return hover.value ? Color.primary.opacity(0.14) : Color.primary.opacity(0.07)
  }
}

private struct PeekButton: View {
  @ObservedObject var pref: PeekPreference

  var body: some View {
    ToggleTile(
      title: "Peek",
      isActive: pref.enabled,
      iconOn: "eye.fill",
      iconOff: "eye.slash",
      activeFill: Color(red: 0.28, green: 0.72, blue: 0.80),
      activeInk: Color(red: 0.04, green: 0.18, blue: 0.22),
      helpOn: "Peek previews are on.",
      helpOff: "Peek previews are off.",
      action: { pref.toggle() })
  }
}

private struct CaffeineButton: View {
  @ObservedObject var caffeine: CaffeineController

  var body: some View {
    ToggleTile(
      title: "Caffeine",
      isActive: caffeine.active,
      iconOn: "cup.and.saucer.fill",
      iconOff: "cup.and.saucer",
      activeFill: Color(red: 0.98, green: 0.74, blue: 0.28),
      activeInk: Color(red: 0.22, green: 0.14, blue: 0.03),
      helpOn: "Keep awake ON. Lid closed still forces clamshell sleep.",
      helpOff: "Click to prevent sleep (caffeinate -dis)",
      action: { caffeine.toggle() })
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
    HStack(spacing: 8) {
      ProcIcon(pid: proc.id)
      Text(proc.name)
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(String(format: "%.1f", proc.cpuPercent))
        .frame(width: 60, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(cpuTint(proc.cpuPercent))
      Text(memString(proc.rssBytes))
        .frame(width: 72, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(.secondary)
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
      Button("Terminate (SIGTERM)") { onKill(proc.id, false) }
      Button("Force Kill (SIGKILL)", role: .destructive) { onKill(proc.id, true) }
    }
  }

  private func memString(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
  }

  private func cpuTint(_ pct: Double) -> Color {
    if pct >= 20 { return .red }
    if pct >= 5 { return .orange }
    return .primary
  }
}

private struct ProcIcon: View {
  let pid: pid_t

  var body: some View {
    switch ProcIconCache.shared.icon(for: pid) {
    case .app(let img):
      Image(nsImage: img)
        .renderingMode(.original)
        .resizable()
        .interpolation(.medium)
        .frame(width: 16, height: 16)
    case .daemon:
      Image(systemName: "gearshape.fill")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
  }
}

enum ProcIconKind {
  case app(NSImage)
  case daemon
}

@MainActor
final class ProcIconCache {
  static let shared = ProcIconCache()
  private var cache: [pid_t: ProcIconKind] = [:]

  func icon(for pid: pid_t) -> ProcIconKind {
    if let hit = cache[pid] { return hit }
    let kind = resolve(pid: pid, depth: 0)
    cache[pid] = kind
    return kind
  }

  // walk up ppids until a process with a bundleURL is found; terminal
  // children (claude, rustc, cargo) inherit their host app icon this way.
  // depth cap prevents a runaway loop on cyclic / orphaned ppid chains.
  private func resolve(pid: pid_t, depth: Int) -> ProcIconKind {
    if depth > 6 || pid <= 1 { return .daemon }
    let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL
    if let url = bundleURL, Self.bundleHasIcon(url) {
      return .app(NSWorkspace.shared.icon(forFile: url.path))
    }
    if let ppid = Self.parentPid(pid) {
      let up = resolve(pid: ppid, depth: depth + 1)
      if case .app = up { return up }
    }
    if let url = bundleURL, !Self.isSystemBundle(url) {
      return .app(NSWorkspace.shared.icon(forFile: url.path))
    }
    return .daemon
  }

  private static func isSystemBundle(_ url: URL) -> Bool {
    let p = url.path
    return p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/")
  }

  // bundles without a declared icon get a generic template placeholder from
  // the file system. prefer walking to a parent with a real icon over
  // showing the template.
  private static func bundleHasIcon(_ url: URL) -> Bool {
    guard let bundle = Bundle(url: url) else { return false }
    if bundle.object(forInfoDictionaryKey: "CFBundleIconFile") != nil { return true }
    if bundle.object(forInfoDictionaryKey: "CFBundleIconName") != nil { return true }
    if let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
      !icons.isEmpty
    {
      return true
    }
    return false
  }

  // uses sysctl kern.proc.pid rather than proc_pidinfo because the latter
  // returns EPERM for setuid root processes (e.g. /usr/bin/login) when the
  // caller is a user process. sysctl exposes kinfo_proc without that gate.
  private static func parentPid(_ pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let r = sysctl(&mib, 4, &info, &size, nil, 0)
    guard r == 0, info.kp_proc.p_pid == pid else { return nil }
    let ppid = info.kp_eproc.e_ppid
    guard ppid > 0 else { return nil }
    return pid_t(ppid)
  }
}
