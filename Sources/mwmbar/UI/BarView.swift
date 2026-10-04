import SwiftUI

struct BarView: View {
  let screenName: String
  let invalidator: Invalidator
  @Environment(BarGeneration.self) private var generation
  let onSwitchWorkspace: (String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void
  let centered: Bool

  var body: some View {
    // reading tick subscribes the view to snapshot commits; the let keeps
    // viewbuilder from discarding it.
    let _ = generation.tick
    let _ = PerfTrace.tick("barview.body")
    let snapshot = invalidator.snapshot()
    let monitor = snapshot.monitors.first { $0.nsScreenName == screenName }
    let visible = Self.visibleWorkspaces(monitor: monitor)
    let totalInnerW = Self.totalInnerWidth(visible: visible)
    PillsRow(
      monitor: monitor,
      visible: visible,
      totalInnerW: totalInnerW,
      onSwitchWorkspace: onSwitchWorkspace,
      onRestoreWindow: onRestoreWindow,
      onPeekEnter: onPeekEnter,
      onPeekExit: onPeekExit,
      focusedWindowId: snapshot.focusedWindowId,
      centered: centered
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
  let onSwitchWorkspace: (String) -> Void
  let onRestoreWindow: (String) -> Void
  let onPeekEnter: (Workspace, CGFloat) -> Void
  let onPeekExit: () -> Void
  let focusedWindowId: String?
  let centered: Bool

  private var outerAlignment: Alignment { centered ? .center : .leading }

  var body: some View {
    HStack(spacing: 0) {
      if let monitor {
        ForEach(visible) { ws in
          WorkspacePill(
            workspace: ws,
            isActive: ws.id == monitor.focusedWorkspaceId,
            focusedWindowId: focusedWindowId,
            onTap: { onSwitchWorkspace(ws.id) },
            onIconClick: { window in
              if window.isHidden {
                onRestoreWindow(window.id)
              } else {
                onSwitchWorkspace(ws.id)
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
        if !centered { Spacer(minLength: 0) }
      }
    }
    // bar background hugs content width while the outer frame stays wide.
    // keeping the HStack at a fixed outer width stops it from retuning its
    // intrinsic size inside the spring animation, which would otherwise
    // jitter pill positions.
    .background(alignment: centered ? .center : .leading) {
      RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: BarConfig.containerCorner, style: .continuous)
            .stroke(BarConfig.containerStroke, lineWidth: 0.5)
        )
        .frame(width: totalInnerW, height: 24)
    }
    .frame(
      maxWidth: .infinity, minHeight: 24, maxHeight: 24,
      alignment: outerAlignment
    )
    // publish bg width so clicks outside it pass through to menubar items
    // underneath.
    .preference(key: BarWidthKey.self, value: totalInnerW)
    .animation(
      .spring(response: 0.32, dampingFraction: 0.78),
      value: AnimationKey(
        visible: visible, focusedWs: monitor?.focusedWorkspaceId, focusedWin: focusedWindowId))
  }
}

/// composite animation key so SwiftUI diffs by Equatable without rebuilding
/// a joined string on every body eval.
private struct AnimationKey: Equatable {
  let visible: [Workspace]
  let focusedWs: String?
  let focusedWin: String?
}
