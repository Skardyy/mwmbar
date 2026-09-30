import SwiftUI

struct BarView: View {
  let monitorId: String
  @Environment(Bar.self) private var state
  let onSwitchWorkspace: (String, String) -> Void

  var body: some View {
    let monitor = state.monitors.first { $0.id == monitorId }
    HStack(spacing: 8) {
      if let monitor {
        ForEach(monitor.workspaces) { ws in
          WorkspacePill(
            workspace: ws,
            isActive: ws.id == monitor.focusedWorkspaceId,
            focusedWindowId: state.focusedWindowId,
            onTap: { onSwitchWorkspace(ws.id, monitorId) }
          )
        }
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    )
  }
}
