import AppKit
import Combine
import SwiftUI

// kept as classic ObservableObject (not @Observable) so @StateObject works
// under the CommandLineTools SDK, which ships without the SwiftUIMacros
// plugin that @Observable / @State would need.
@MainActor
private final class HoverFlag: ObservableObject {
  @Published var value = false
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

enum NetworkSortColumn: Sendable {
  case ip
  case name
  case interfaceName
}

enum NetworkSubTab: String, CaseIterable, Identifiable {
  case interfaces = "Interfaces"
  case mdns = "mDNS"
  case ports = "Ports"
  var id: String { rawValue }
}

struct NetworkTab: View {
  @Bindable var model: DashboardModel
  let store: NetworkStore
  let onKill: (pid_t, Bool) -> Void
  @Environment(NetworkGeneration.self) private var generation

  var body: some View {
    let _ = generation.tick
    let snap = store.snapshot()
    VStack(spacing: 10) {
      summary(snap: snap)
      Divider()
      subTabPicker
      switch model.networkSubTab {
      case .mdns:
        search
        columnHeader
        lanList(devices: filtered(snap.lan), interfaces: snap.interfaces)
      case .interfaces:
        interfacesList(sortedInterfaces(snap.interfaces), defaultName: snap.linkName)
      case .ports:
        portsList(sortedPorts(snap.ports))
      }
    }
  }

  // tcp before udp, then by port ascending so clustered dev server ranges
  // (3000, 5173, 8080...) read top to bottom in the order you'd guess them.
  private func sortedPorts(_ ports: [PortInfo]) -> [PortInfo] {
    ports.sorted { a, b in
      if a.proto != b.proto { return a.proto == .tcp }
      return a.port < b.port
    }
  }

  private func portsList(_ ports: [PortInfo]) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(ports) { port in
          PortRow(port: port, onKill: onKill)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var subTabPicker: some View {
    HStack(spacing: 2) {
      ForEach(NetworkSubTab.allCases) { tab in
        FilterChip(
          label: tab.rawValue,
          selected: model.networkSubTab == tab,
          action: { model.networkSubTab = tab })
      }
      Spacer()
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04)))
  }

  // active with an ip first (the interfaces actually carrying traffic),
  // then active without one (bridge/virtual interfaces up but idle), then
  // up but not running, then down, loopback always last regardless of
  // state since it is never the thing a user is checking for.
  private static let kindOrder: [InterfaceKind] = [.wifi, .ethernet, .bridge, .vpn, .other]

  private func sortedInterfaces(_ interfaces: [InterfaceInfo]) -> [InterfaceInfo] {
    func tier(_ i: InterfaceInfo) -> Int {
      if i.isLoopback { return 4 }
      if i.isUp && i.isRunning && i.ipv4 != nil { return 0 }
      if i.isUp && i.isRunning { return 1 }
      if i.isUp { return 2 }
      return 3
    }
    func kindRank(_ i: InterfaceInfo) -> Int {
      Self.kindOrder.firstIndex(of: i.kind) ?? Self.kindOrder.count
    }
    return interfaces.sorted { a, b in
      let ta = tier(a)
      let tb = tier(b)
      if ta != tb { return ta < tb }
      let ka = kindRank(a)
      let kb = kindRank(b)
      if ka != kb { return ka < kb }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }

  private func interfacesList(_ interfaces: [InterfaceInfo], defaultName: String?) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(interfaces) { iface in
          InterfaceRow(iface: iface, isDefault: defaultName != nil && iface.name == defaultName)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func summary(snap: NetworkSnapshot) -> some View {
    HStack(spacing: 8) {
      InfoTile(
        icon: "globe",
        label: "Public IP",
        value: snap.publicIP ?? "-",
        copyable: snap.publicIP)
      InfoTile(
        icon: "lock.shield.fill",
        label: "VPN",
        value: snap.vpnActive ? "Active" : "Off",
        valueTint: snap.vpnActive ? .green : .secondary)
    }
  }

  private var search: some View {
    TextField("Filter by ip / name / service", text: $model.networkSearch)
      .textFieldStyle(.roundedBorder)
  }

  private var columnHeader: some View {
    HStack(spacing: 4) {
      NetworkSortHeader(
        label: "NIC", column: .interfaceName, model: model, width: 70, alignment: .leading)
      NetworkSortHeader(
        label: "IP", column: .ip, model: model, width: 120, alignment: .leading)
      NetworkSortHeader(
        label: "Name / services", column: .name, model: model, alignment: .leading
      )
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 4)
  }

  private func lanList(devices: [LanDevice], interfaces: [InterfaceInfo]) -> some View {
    let kindByName = Dictionary(
      uniqueKeysWithValues: interfaces.map { ($0.name, $0.kind) })
    return ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(devices) { d in
          LanRow(device: d, kind: d.interfaceName.flatMap { kindByName[$0] })
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
    case .interfaceName:
      sorted = base.sorted {
        ($0.interfaceName ?? "").localizedStandardCompare($1.interfaceName ?? "")
          == .orderedAscending
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

private struct NetworkSortHeader: View {
  let label: String
  let column: NetworkSortColumn
  @Bindable var model: DashboardModel
  var width: CGFloat? = nil
  var alignment: HorizontalAlignment = .leading
  @StateObject private var hover = HoverFlag()

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
  var copyable: String? = nil
  @StateObject private var hover = HoverFlag()
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

/// both LanRow and InterfaceRow lock to this so the list does not jump
/// height depending on whether a row's optional second line is present.
private let networkRowHeight: CGFloat = 40

private struct LanRow: View {
  let device: LanDevice
  let kind: InterfaceKind?
  @StateObject private var hover = HoverFlag()
  @StateObject private var copied = CopiedFlag()

  // mdns names are the device's own real hostname; arp entries only ever
  // have a mac vendor guess, so the label makes that distinction explicit
  // rather than let an oui guess read as confidently as a real hostname.
  private var sourceBadge: some View {
    let label = device.source == .mdns ? "mDNS" : "OUI"
    let tint: Color = device.source == .mdns ? .orange : .secondary
    return Text(label)
      .font(.system(size: 8, weight: .bold))
      .foregroundStyle(tint)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Capsule().fill(tint.opacity(0.15)))
  }

  var body: some View {
    Button {
      copyToClipboard(device.ip)
      copied.flash()
    } label: {
      HStack(spacing: 10) {
        HStack(spacing: 6) {
          Image(systemName: (kind ?? .other).icon)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 12)
          Text(device.interfaceName ?? "-")
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
        }
        .frame(width: 70, alignment: .leading)
        Text(copied.value ? "copied" : device.ip)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(copied.value ? .green : .primary)
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
        sourceBadge
      }
      .frame(height: networkRowHeight)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hover.value ? Color.primary.opacity(0.08) : .clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
  }
}

private func copyToClipboard(_ value: String) {
  let pb = NSPasteboard.general
  pb.clearContents()
  pb.setString(value, forType: .string)
}

private struct InterfaceRow: View {
  let iface: InterfaceInfo
  let isDefault: Bool
  @StateObject private var hover = HoverFlag()
  @StateObject private var copied = CopiedFlag()

  // "active" means carrying a real ip, not merely IFF_UP|IFF_RUNNING: a
  // bridge or virtual interface sits up+running at all times whether or
  // not anything is actually plugged into it.
  private var statusColor: Color {
    switch statusLabel {
    case "active": return .green
    case "no ip": return .orange
    case "up": return .orange
    default: return .secondary
    }
  }

  private var statusLabel: String {
    if iface.isLoopback { return "loopback" }
    if iface.isUp && iface.isRunning && iface.ipv4 != nil { return "active" }
    if iface.isUp && iface.isRunning { return "no ip" }
    if iface.isUp { return "up" }
    return "down"
  }

  var body: some View {
    Button {
      guard let ip = iface.ipv4 else { return }
      copyToClipboard(ip)
      copied.flash()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: iface.kind.icon)
          .font(.system(size: 12))
          .foregroundStyle(statusColor)
          .frame(width: 16)
          .help(iface.kind.label)
        Text(iface.name)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .frame(width: 80, alignment: .leading)
        VStack(alignment: .leading, spacing: 1) {
          Text(copied.value ? "copied" : (iface.ipv4 ?? "-"))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(copied.value ? .green : (iface.ipv4 != nil ? .primary : .secondary))
          if let mac = iface.mac {
            Text(mac)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isDefault {
          Text("DEFAULT")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.15)))
        }
        Text(statusLabel)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(statusColor)
      }
      .frame(height: networkRowHeight)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hover.value ? Color.primary.opacity(0.08) : .clear)
      )
    }
    .buttonStyle(.plain)
    .disabled(iface.ipv4 == nil)
    .onHover { hover.value = $0 }
  }
}

private struct PortRow: View {
  let port: PortInfo
  let onKill: (pid_t, Bool) -> Void
  @StateObject private var hover = HoverFlag()
  @StateObject private var copied = CopiedFlag()

  private var secondLine: String {
    guard let folder = port.folder, folder != "/" else { return "pid \(port.pid)" }
    return "pid \(port.pid)  -  \(folder)"
  }

  var body: some View {
    Button {
      copyToClipboard(String(port.port))
      copied.flash()
    } label: {
      HStack(spacing: 10) {
        Text(port.proto.rawValue)
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(port.proto == .tcp ? .blue : .purple)
          .frame(width: 32, alignment: .leading)
        Text(copied.value ? "copied" : String(port.port))
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(copied.value ? .green : .primary)
          .frame(width: 60, alignment: .leading)
        VStack(alignment: .leading, spacing: 1) {
          Text(port.command)
            .font(.system(size: 12))
            .lineLimit(1).truncationMode(.tail)
          Text(secondLine)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let age = port.age {
          Text(age)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .trailing)
        }
      }
      .frame(height: networkRowHeight)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hover.value ? Color.primary.opacity(0.08) : .clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
    .contextMenu {
      Button("Terminate (SIGTERM)") { onKill(port.pid, false) }
      Button("Force Kill (SIGKILL)", role: .destructive) { onKill(port.pid, true) }
    }
  }
}
