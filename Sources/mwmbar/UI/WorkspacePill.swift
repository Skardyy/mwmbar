import SwiftUI

struct WorkspacePill: View {
  let workspace: Workspace
  let isActive: Bool
  let focusedWindowId: String?
  let onTap: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Text(workspace.id)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .frame(minWidth: 14)
      ForEach(workspace.windows) { w in
        WindowIcon(window: w, isFocused: w.id == focusedWindowId)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
  }
}
