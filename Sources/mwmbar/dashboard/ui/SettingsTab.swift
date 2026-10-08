import AppKit
import SwiftUI

struct SettingsTab: View {
  @ObservedObject var caffeine: CaffeineController
  @ObservedObject var peekPref: PeekPreference

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 10) {
        SettingCard(
          icon: "eye.fill",
          title: "Peek",
          description: "hover a workspace pill to see live window thumbnails",
          isActive: peekPref.enabled,
          activeFill: Color(red: 0.28, green: 0.72, blue: 0.80),
          onToggle: { peekPref.toggle() })
        SettingCard(
          icon: "cup.and.saucer.fill",
          title: "Caffeine",
          description: "prevent system sleep (lid closed still forces clamshell)",
          isActive: caffeine.active,
          activeFill: Color(red: 0.98, green: 0.74, blue: 0.28),
          onToggle: { caffeine.toggle() })
      }
      .padding(.horizontal, 4)
    }
  }
}

@MainActor
private final class CardHover: ObservableObject {
  @Published var value = false
}

private struct SettingCard: View {
  let icon: String
  let title: String
  let description: String
  let isActive: Bool
  let activeFill: Color
  let onToggle: () -> Void
  @StateObject private var hover = CardHover()

  var body: some View {
    Button(action: onToggle) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isActive ? activeFill : .secondary)
            .frame(width: 28, height: 28)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? activeFill.opacity(0.18) : Color.primary.opacity(0.08))
            )
          Text(title)
            .font(.system(size: 13, weight: .semibold))
          Spacer(minLength: 0)
          Text(isActive ? "On" : "Off")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isActive ? activeFill : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
              Capsule().fill(
                isActive ? activeFill.opacity(0.18) : Color.primary.opacity(0.08))
            )
        }
        Text(description)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(hover.value ? Color.primary.opacity(0.06) : .clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isActive ? activeFill.opacity(0.4) : Color.primary.opacity(0.1),
            lineWidth: isActive ? 1.2 : 0.5)
      )
      .animation(.easeOut(duration: 0.12), value: hover.value)
      .animation(.easeOut(duration: 0.18), value: isActive)
    }
    .buttonStyle(.plain)
    .onHover { hover.value = $0 }
  }
}
