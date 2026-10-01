import AppKit
import Combine
import SwiftUI

struct PillFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

/// not @MainActor so onPreferenceChange's non isolated closure can write
/// synchronously; both reads and writes happen from the SwiftUI update loop
/// in practice.
final class PillGeomModel: ObservableObject, @unchecked Sendable {
  @Published var frame: CGRect = .zero
}

struct WorkspacePill: View {
  let workspace: Workspace
  let isActive: Bool
  let focusedWindowId: String?
  let onTap: () -> Void
  let onIconClick: (Window) -> Void
  let onPeekEnter: (CGFloat) -> Void
  let onPeekExit: () -> Void

  @StateObject private var hover = HoverModel()
  @StateObject private var geom = PillGeomModel()

  var body: some View {
    HStack(spacing: BarConfig.iconGap) {
      Text(workspace.id)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .frame(minWidth: 14)
      ForEach(workspace.windows) { w in
        WindowIcon(
          window: w,
          isFocused: isActive && w.id == focusedWindowId,
          onClick: { onIconClick(w) })
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(fillView)
    .overlay(strokeView)
    .scaleEffect(isActive ? BarConfig.activePillScale : 1.0)
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .background(
      GeometryReader { geo in
        let frame = geo.frame(in: .named("bar"))
        Color.clear
          .task(id: frame) { geom.frame = frame }
      }
    )
    .onHover { over in
      hover.value = over
      if over {
        onPeekEnter(geom.frame.midX)
      } else {
        onPeekExit()
      }
    }
    .animation(BarConfig.transition, value: isActive)
    .animation(BarConfig.hoverTransition, value: hover.value)
    .animation(BarConfig.transition, value: workspace.windows)
  }

  @ViewBuilder private var fillView: some View {
    RoundedRectangle(cornerRadius: BarConfig.pillCorner, style: .continuous)
      .fill(currentFill)
  }

  @ViewBuilder private var strokeView: some View {
    RoundedRectangle(cornerRadius: BarConfig.pillCorner, style: .continuous)
      .stroke(isActive ? BarConfig.activeStroke : .clear, lineWidth: isActive ? 1.2 : 0)
      .shadow(color: isActive ? BarConfig.activeStroke : .clear, radius: isActive ? 4 : 0)
  }

  private var currentFill: Color {
    if isActive { return hover.value ? BarConfig.hoverActiveFill : BarConfig.activeFill }
    return hover.value ? BarConfig.hoverFill : .clear
  }
}
