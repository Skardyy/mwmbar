import AppKit
import SwiftUI

struct NetworkTab: View {
  let store: NetworkStore
  let onScan: () -> Void
  @Environment(NetworkGeneration.self) private var generation

  var body: some View {
    let _ = generation.tick
    let snap = store.snapshot()
    VStack(spacing: 10) {
      summary(snap: snap)
      Divider()
      scanControls(snap: snap)
      lanList(devices: snap.lan)
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

  private func scanControls(snap: NetworkSnapshot) -> some View {
    HStack(spacing: 8) {
      if snap.scanning {
        Button("Stop", systemImage: "stop.fill") { onScan() }
          .tint(.red)
        ProgressView()
          .controlSize(.small)
        Text("Listening for ARP...")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      } else {
        Button("Start Scan", systemImage: "dot.radiowaves.left.and.right") { onScan() }
      }
      Spacer()
      if let date = snap.lastScanned, !snap.scanning {
        Text("Last scan \(timeAgo(date))")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func lanList(devices: [LanDevice]) -> some View {
    Group {
      if devices.isEmpty {
        Text("No devices to show")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
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
    }
  }

  private func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
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
  let level: Int  // 0..4

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
      Text(device.hostname ?? "-")
        .font(.system(size: 12))
        .lineLimit(1).truncationMode(.middle)
        .foregroundStyle(device.hostname == nil ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(device.mac)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
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
