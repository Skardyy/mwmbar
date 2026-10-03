import AppKit
import Combine
import SwiftUI

@MainActor
final class PillHover: ObservableObject {
  @Published var value = false
  /// not @Published; written every layout tick but read imperatively and
  /// bound to no view, so publishing would churn redraws for nothing.
  var midX: CGFloat = 0
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
  @Environment(WallpaperTint.self) private var tint

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
        // per icon transition. pairs with the enclosing animation driven by
        // the pill's window fingerprint so icons pop in and out individually
        // instead of the whole pill resizing in one step.
        .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
      }
    }
    // pin content height to the icon size so a label only pill matches the
    // height of a pill that contains an icon. without this the two kinds
    // of pills sit on different baselines.
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
        .stroke(isActive ? (tint.activeStroke ?? BarConfig.activeStroke) : .clear, lineWidth: 1.2)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    // publish pill midX in the shared "bar" coordinate space so the peek
    // anchor can line up; onGeometryChange's action runs outside the
    // layout pass so writes are safe.
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.frame(in: .named("bar")).midX
    } action: { midX in
      hover.midX = midX
    }
    .onHover { over in
      hover.value = over
      if over { onPeekEnter(hover.midX) } else { onPeekExit() }
    }
  }

  private var currentFill: Color {
    if isActive {
      let active = tint.activeFill ?? BarConfig.activeFill
      let hoverActive = tint.hoverActiveFill ?? BarConfig.hoverActiveFill
      return hover.value ? hoverActive : active
    }
    return hover.value ? BarConfig.hoverFill : .clear
  }
}
