import SwiftUI

struct BarView: View {
  let monitorId: String
  @Environment(Bar.self) private var state
  let onSwitchWorkspace: (String, String) -> Void
  let onRestoreWindow: (String) -> Void

  var body: some View {
    let monitor = state.monitors.first { $0.id == monitorId }
    HStack(spacing: 6) {
      if let monitor {
        // hide empty workspaces; always keep the focused one so the current pos stays visible.
        let visible = monitor.workspaces.filter {
          !$0.windows.isEmpty || $0.id == monitor.focusedWorkspaceId
        }
        ForEach(visible) { ws in
          WorkspacePill(
            workspace: ws,
            isActive: ws.id == monitor.focusedWorkspaceId,
            focusedWindowId: state.focusedWindowId,
            onTap: { onSwitchWorkspace(ws.id, monitorId) },
            onIconClick: { window in
              if window.isHidden {
                onRestoreWindow(window.id)
              } else {
                onSwitchWorkspace(ws.id, monitorId)
              }
            }
          )
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.7).combined(with: .opacity),
              removal: .scale(scale: 0.7).combined(with: .opacity)))
        }
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 24)
    .background(
      RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
            .stroke(BarConfig.containerStroke, lineWidth: 0.5)
        )
    )
    .animation(BarConfig.transition, value: monitor?.workspaces ?? [])
  }
}
