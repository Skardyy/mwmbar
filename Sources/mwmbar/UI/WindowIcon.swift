import AppKit
import Combine
import SwiftUI

// hover flag shared by icon and pill. kept as a classic ObservableObject so
// @StateObject works under the CommandLineTools SDK, which ships without the
// SwiftUIMacros plugin that @Observable / @State would need.
@MainActor
final class HoverModel: ObservableObject {
  @Published var value = false
}

// id of whichever icon the cursor is currently over, or nil if none.
// a global NSEvent middle click monitor in Controller reads this to close
// the hovered window. SwiftUI gestures do not expose other mouse buttons,
// so the AppKit monitor and this shared registry are both load bearing.
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
      .scaleEffect(scale)

      if window.isHidden {
        Circle()
          .fill(BarConfig.hiddenBadgeFill)
          .frame(width: 6, height: 6)
          .overlay(Circle().stroke(BarConfig.hiddenBadgeStroke, lineWidth: 0.5))
          .offset(x: 2, y: 2)
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
    isFocused ? BarConfig.focusedScale : 1.0
  }

}
