import AppKit
import SwiftUI

enum NetworkSortColumn: Sendable {
  case ip
  case name
}

struct NetworkTab: View {
  @Bindable var model: DashboardModel
  let store: NetworkStore
  @Environment(NetworkGeneration.self) private var generation

  var body: some View {
    let _ = generation.tick
    let snap = store.snapshot()
    VStack(spacing: 10) {
      summary(snap: snap)
      Divider()
      search
      columnHeader
      lanList(devices: filtered(snap.lan))
    }
  }

  private func summary(snap: NetworkSnapshot) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        InfoTile(
          icon: snap.linkKind.icon,
          label: linkLabel(snap.linkKind),
          value: snap.linkName ?? "(not connected)",
          trailing: snap.signalBars.map { AnyView(SignalBars(level: $0)) })
        InfoTile(
          icon: "lock.shield.fill",
          label: "VPN",
          value: snap.vpnActive ? "Active" : "Off",
          valueTint: snap.vpnActive ? .green : .secondary)
      }
      HStack(spacing: 8) {
        InfoTile(
          icon: "network",
          label: "Local IP",
          value: snap.localIP ?? "-",
          copyable: snap.localIP)
        InfoTile(
          icon: "globe",
          label: "Public IP",
          value: snap.publicIP ?? "-",
          copyable: snap.publicIP)
      }
    }
  }

  private func linkLabel(_ kind: LinkKind) -> String {
    switch kind {
    case .wifi: return "Wi-Fi"
    case .wired: return "LAN"
    case .vpn: return "VPN link"
    case .unknown: return "Link"
    }
  }

  private var search: some View {
    TextField("Filter by ip / name / service", text: $model.networkSearch)
      .textFieldStyle(.roundedBorder)
  }

  private var columnHeader: some View {
    HStack(spacing: 4) {
      NetworkSortHeader(
        label: "IP", column: .ip, model: model, width: 120, alignment: .leading)
      NetworkSortHeader(
        label: "Name / services", column: .name, model: model, alignment: .leading
      )
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 4)
  }

  private func lanList(devices: [LanDevice]) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(devices) { d in
          LanRow(device: d)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func filtered(_ devices: [LanDevice]) -> [LanDevice] {
    let needle = model.networkSearch.lowercased()
    let base =
      needle.isEmpty
      ? devices
      : devices.filter { d in
        if d.ip.lowercased().contains(needle) { return true }
        if let host = d.hostname, host.lowercased().contains(needle) { return true }
        return d.services.contains { $0.lowercased().contains(needle) }
      }
    let sorted: [LanDevice]
    switch model.networkSortColumn {
    case .ip:
      sorted = base.sorted { ipOrder($0.ip) < ipOrder($1.ip) }
    case .name:
      sorted = base.sorted {
        ($0.hostname ?? "").localizedCompare($1.hostname ?? "") == .orderedAscending
      }
    }
    return model.networkSortAsc ? sorted : sorted.reversed()
  }

  private func ipOrder(_ ip: String) -> UInt32 {
    let parts = ip.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4 else { return 0 }
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
  }
}

@MainActor
private final class SortHoverState: ObservableObject {
  @Published var value = false
}

private struct NetworkSortHeader: View {
  let label: String
  let column: NetworkSortColumn
  @Bindable var model: DashboardModel
  var width: CGFloat? = nil
  var alignment: HorizontalAlignment = .leading
  @StateObject private var hover = SortHoverState()

  var body: some View {
    Button {
      model.toggleNetworkSort(column)
    } label: {
      HStack(spacing: 3) {
        if alignment == .trailing { Spacer(minLength: 0) }
        Text(label)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(active ? Color.primary : .secondary)
        Image(systemName: model.networkSortAsc ? "chevron.up" : "chevron.down")
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
    .modifier(OptionalWidth(width: width))
  }

  private var active: Bool { model.networkSortColumn == column }
}

private struct OptionalWidth: ViewModifier {
  let width: CGFloat?
  func body(content: Content) -> some View {
    if let width { content.frame(width: width) } else { content }
  }
}

private struct InfoTile: View {
  let icon: String
  let label: String
  let value: String
  var valueTint: Color = .primary
  var trailing: AnyView? = nil
  var copyable: String? = nil
  @StateObject private var hover = InfoHover()
  @StateObject private var copied = CopiedFlag()

  var body: some View {
    let content = VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Text(label.uppercased())
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .tracking(0.4)
        Spacer(minLength: 0)
        if let trailing = trailing { trailing }
      }
      HStack(spacing: 4) {
        Text(copied.value ? "copied" : value)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(copied.value ? .green : valueTint)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(fill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
    .animation(.easeOut(duration: 0.15), value: copied.value)
    .animation(.easeOut(duration: 0.1), value: hover.value)
    .onHover { hover.value = $0 }

    if let copyable = copyable {
      Button {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(copyable, forType: .string)
        copied.flash()
      } label: {
        content
      }
      .buttonStyle(.plain)
      .help("Click to copy")
    } else {
      content
    }
  }

  private var fill: Color {
    if copyable != nil, hover.value {
      return Color.primary.opacity(0.1)
    }
    return Color.primary.opacity(0.05)
  }
}

@MainActor
private final class CopiedFlag: ObservableObject {
  @Published var value = false
  private var task: Task<Void, Never>?

  func flash() {
    task?.cancel()
    value = true
    task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      if Task.isCancelled { return }
      self?.value = false
    }
  }
}

@MainActor
private final class InfoHover: ObservableObject {
  @Published var value = false
}

private struct SignalBars: View {
  let level: Int

  var body: some View {
    HStack(spacing: 1.5) {
      ForEach(1...4, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(i <= level ? Color.primary : Color.secondary.opacity(0.25))
          .frame(width: 3, height: CGFloat(3 + i * 2))
      }
    }
    .frame(height: 12)
  }
}

private struct LanRow: View {
  let device: LanDevice
  @StateObject private var hover = InfoHover()

  var body: some View {
    HStack(spacing: 10) {
      Text(device.ip)
        .font(.system(size: 12, design: .monospaced))
        .frame(width: 120, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(device.hostname ?? "-")
          .font(.system(size: 12))
          .lineLimit(1).truncationMode(.middle)
          .foregroundStyle(device.hostname != nil ? .primary : .secondary)
        if !device.services.isEmpty {
          Text(device.services.joined(separator: ", "))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hover.value ? Color.primary.opacity(0.08) : .clear)
    )
    .onHover { hover.value = $0 }
  }
}
