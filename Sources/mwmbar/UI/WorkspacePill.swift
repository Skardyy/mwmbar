import AppKit
import SwiftUI

struct WorkspacePill: View {
  let workspace: Workspace
  let isActive: Bool
  let focusedWindowId: String?
  let onTap: () -> Void
  let onIconClick: (Window) -> Void

  @StateObject private var hover = HoverModel()

  var body: some View {
    HStack(spacing: BarConfig.iconGap) {
      Text(workspace.id)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .frame(minWidth: 14)
      ForEach(workspace.windows) { w in
        WindowIcon(
          window: w,
          isFocused: w.id == focusedWindowId,
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
    .onHover { over in hover.value = over }
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
