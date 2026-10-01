import AppKit
import Combine
import SwiftUI

/// hover flag shared by icon and pill. classic ObservableObject so @StateObject
/// works with the CommandLineTools SDK (no SwiftUIMacros plugin for @State).
@MainActor
final class HoverModel: ObservableObject {
  @Published var value = false
}

/// window id of whichever icon the cursor is over, or nil if none.
@MainActor
final class IconHoverRegistry {
  static let shared = IconHoverRegistry()
  var hoveredWindowId: String?
}

struct WindowIcon: View {
  let window: Window
  let isFocused: Bool
  let onClick: () -> Void

  @StateObject private var hover = HoverModel()

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if let img = IconCache.shared.icon(for: window.bundleId) {
          Image(nsImage: img).resizable().scaledToFit()
        } else {
          Color.gray.opacity(0.3)
        }
      }
      .frame(width: BarConfig.iconSize, height: BarConfig.iconSize)
      .opacity(effectiveOpacity)
      .compositingGroup()
      .scaleEffect(scale)
      .shadow(
        color: isFocused ? BarConfig.focusedGlow : .clear,
        radius: isFocused ? 4 : 0
      )
      .animation(BarConfig.hoverTransition, value: hover.value)
      .animation(BarConfig.transition, value: window.isHidden)
      .animation(BarConfig.transition, value: isFocused)

      if window.isHidden {
        Circle()
          .fill(BarConfig.hiddenBadgeFill)
          .frame(width: 6, height: 6)
          .overlay(Circle().stroke(BarConfig.hiddenBadgeStroke, lineWidth: 0.5))
          .offset(x: 2, y: 2)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .contentShape(Rectangle())
    .onHover { over in
      hover.value = over
      let registry = IconHoverRegistry.shared
      if over {
        registry.hoveredWindowId = window.id
      } else if registry.hoveredWindowId == window.id {
        registry.hoveredWindowId = nil
      }
    }
    .onTapGesture(perform: onClick)
    .animation(BarConfig.transition, value: window.isHidden)
  }

  private var effectiveOpacity: Double {
    let base: Double
    if window.isHidden {
      base = BarConfig.hiddenOpacity
    } else if isFocused {
      base = BarConfig.focusedOpacity
    } else {
      base = BarConfig.inactiveOpacity
    }
    return hover.value ? min(1.0, base + BarConfig.hoverIconBoost) : base
  }

  private var scale: CGFloat {
    if isFocused { return BarConfig.focusedScale }
    return 1.0
  }

}
