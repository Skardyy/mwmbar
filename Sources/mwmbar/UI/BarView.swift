import SwiftUI

struct BarView: View {
  let monitorId: String
  @Environment(Bar.self) private var state
  let onSwitchWorkspace: (String, String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void

  var body: some View {
    let monitor = state.monitors.first { $0.id == monitorId }
    content(monitor: monitor)
      .coordinateSpace(.named("bar"))
  }

  @ViewBuilder
  private func content(monitor: Monitor?) -> some View {
    let visible = monitor?.workspaces.filter {
      !$0.windows.isEmpty || $0.id == monitor?.focusedWorkspaceId
    } ?? []
    let fingerprint = visible.map {
      "\($0.id)|\($0.windows.map { "\($0.id):\($0.isHidden ? 1 : 0)" }.joined(separator: ","))"
    }
    let focusedWs = monitor?.focusedWorkspaceId ?? ""
    let focusedWin = state.focusedWindowId ?? ""

    let totalInnerW = visible.reduce(0.0) { acc, ws in
      let base: CGFloat = 14 + 14
      let n = CGFloat(ws.windows.count)
      let w = n == 0 ? base : base + n * BarConfig.iconSize + n * BarConfig.iconGap
      return acc + w
    }

    HStack(spacing: 0) {
      if let monitor {
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
            },
            onPeekEnter: { x in onPeekEnter(ws, x) },
            onPeekExit: onPeekExit
          )
          .zIndex(1)
          .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 6)
    // bar BG hugs content width (totalInnerW + horizontal padding). the
    // outer frame stays at 800pt so the HStack never has to retune its
    // intrinsic size inside the implicit spring and pills don't drift.
    .background(alignment: .leading) {
      RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
            .stroke(BarConfig.containerStroke, lineWidth: 0.5)
        )
        .frame(width: totalInnerW + 12, height: 24)
    }
    .frame(maxWidth: .infinity, maxHeight: 24, alignment: .leading)
    .frame(height: 24)
    // publish current bar BG width so the hosting view can reject clicks
    // outside it (menubar items under the invisible excess area stay clickable).
    .preference(key: BarWidthKey.self, value: totalInnerW + 12)
    .animation(
      .spring(response: 0.32, dampingFraction: 0.78),
      value: fingerprint + [focusedWs, focusedWin])
  }
}
