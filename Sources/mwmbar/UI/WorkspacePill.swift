import AppKit
import Combine
import SwiftUI

@MainActor
final class PillHover: ObservableObject {
  @Published var value = false
  @Published var midX: CGFloat = 0
}

struct WorkspacePill: View {
  let workspace: Workspace
  let isActive: Bool
  let focusedWindowId: String?
  let onTap: () -> Void
  let onIconClick: (Window) -> Void
  let onPeekEnter: (CGFloat) -> Void
  let onPeekExit: () -> Void

  @StateObject private var hover = PillHover()

  private var targetWidth: CGFloat {
    let base: CGFloat = 14 + 14
    let n = CGFloat(workspace.windows.count)
    if n == 0 { return base }
    return base + n * BarConfig.iconSize + n * BarConfig.iconGap
  }

  var body: some View {
    HStack(spacing: BarConfig.iconGap) {
      Text(workspace.id)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .frame(width: 14, alignment: .center)
      ForEach(workspace.windows) { w in
        WindowIcon(
          window: w,
          isFocused: isActive && w.id == focusedWindowId,
          onClick: { onIconClick(w) }
        )
        .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
      }
    }
    // force content height = icon size so empty pills (label only) match
    // the height of pills that contain an icon.
    .frame(height: BarConfig.iconSize)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .frame(width: targetWidth, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: BarConfig.pillCorner, style: .continuous)
        .fill(currentFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: BarConfig.pillCorner, style: .continuous)
        .stroke(isActive ? BarConfig.activeStroke : .clear, lineWidth: 1.2)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .background(
      GeometryReader { geo in
        let frame = geo.frame(in: .named("bar"))
        Color.clear.task(id: frame.midX) { hover.midX = frame.midX }
      }
    )
    .onHover { over in
      hover.value = over
      if over { onPeekEnter(hover.midX) } else { onPeekExit() }
    }
  }

  private var currentFill: Color {
    if isActive { return hover.value ? BarConfig.hoverActiveFill : BarConfig.activeFill }
    return hover.value ? BarConfig.hoverFill : .clear
  }
}
