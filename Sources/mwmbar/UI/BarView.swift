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
    let visible = Self.visibleWorkspaces(monitor: monitor)
    // record counter inside the let chain so ViewBuilder treats it as data
    // (binding to _ consumed via subsequent compute) not as a view result.
    let totalInnerW =
      Self.totalInnerWidth(visible: visible)
      + CGFloat(0 * PerfTrace.tick("barview.body"))
    PillsRow(
      monitor: monitor,
      visible: visible,
      totalInnerW: totalInnerW,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit,
      monitorId: monitorId,
      focusedWindowId: state.focusedWindowId
    )
    .coordinateSpace(.named("bar"))
  }

  private static func visibleWorkspaces(monitor: Monitor?) -> [Workspace] {
    monitor?.workspaces.filter {
      !$0.windows.isEmpty || $0.id == monitor?.focusedWorkspaceId
    } ?? []
  }

  private static func totalInnerWidth(visible: [Workspace]) -> CGFloat {
    visible.reduce(0.0) { acc, ws in
      let base: CGFloat = 14 + 14
      let n = CGFloat(ws.windows.count)
      let w = n == 0 ? base : base + n * BarConfig.iconSize + n * BarConfig.iconGap
      return acc + w
    }
  }
}

private struct PillsRow: View {
  let monitor: Monitor?
  let visible: [Workspace]
  let totalInnerW: CGFloat
  let onSwitchWorkspace: (String, String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void
  let monitorId: String
  let focusedWindowId: String?

  var body: some View {
    HStack(spacing: 0) {
      if let monitor {
        ForEach(visible) { ws in
          WorkspacePill(
            workspace: ws,
            isActive: ws.id == monitor.focusedWorkspaceId,
            focusedWindowId: focusedWindowId,
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
          // zIndex is required. without it, SwiftUI ForEach removal
          // transitions let the departing pill drift its siblings sideways.
          .zIndex(1)
          .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
        }
        Spacer(minLength: 0)
      }
    }
    // bar background hugs content width while the outer frame stays wide.
    // keeping the HStack at a fixed outer width stops it from retuning its
    // intrinsic size inside the spring animation, which would otherwise
    // jitter pill positions.
    .background(alignment: .leading) {
      RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
            .stroke(BarConfig.containerStroke, lineWidth: 0.5)
        )
        .frame(width: totalInnerW, height: 24)
    }
    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
    // publish the current background width so the hosting window can reject
    // clicks that fall outside it. menubar items sitting under the invisible
    // excess area must stay clickable.
    .preference(key: BarWidthKey.self, value: totalInnerW)
    .animation(
      .spring(response: 0.32, dampingFraction: 0.78),
      value: AnimationKey(
        visible: visible, focusedWs: monitor?.focusedWorkspaceId, focusedWin: focusedWindowId))
  }
}

/// composite animation key. SwiftUI diffs by Equatable; combining the three
/// signals into one struct avoids rebuilding a joined string on every body
/// re evaluation.
private struct AnimationKey: Equatable {
  let visible: [Workspace]
  let focusedWs: String?
  let focusedWin: String?
}
