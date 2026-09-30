import SwiftUI

struct WindowIcon: View {
  let window: Window
  let isFocused: Bool

  var body: some View {
    Group {
      if let img = IconCache.shared.icon(for: window.bundleId) {
        Image(nsImage: img).resizable().scaledToFit()
      } else {
        Color.gray.opacity(0.3)
      }
    }
    .frame(width: 16, height: 16)
    .opacity(window.isHidden ? 0.5 : (isFocused ? 1.0 : 0.75))
  }
}
