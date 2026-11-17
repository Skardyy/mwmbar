import AppKit
import SwiftUI

struct StorageTab: View {
  @ObservedObject var storage: StorageController

  var body: some View {
    VStack(spacing: 10) {
      header
      if storage.items.isEmpty {
        Spacer()
        Text(
          storage.hasScanned
            ? "Nothing found worth reclaiming."
            : "Hit Check to scan known caches and project build folders."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        Spacer()
      } else {
        list
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Total: \(ByteFormat.string(totalBytes))")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      if storage.isScanning {
        ProgressView().controlSize(.small)
      }
      Spacer()
      Button(storage.isScanning ? "Checking..." : "Check") {
        storage.check()
      }
      .disabled(storage.isScanning)
    }
  }

  private var totalBytes: Int64 {
    storage.items.reduce(0) { $0 + $1.sizeBytes }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(storage.items) { item in
          StorageRow(
            item: item, isClearing: storage.clearingIds.contains(item.id),
            didFail: storage.failedIds.contains(item.id),
            onClear: { storage.clear(item) })
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

enum ByteFormat {
  static func string(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

// collapses the home dir to ~, and abbreviates the first path component
// after it to a single letter (Desktop -> D) since that top level folder
// name is rarely the identifying part of a long path. split into three
// pieces so the UI can color ~ and the abbreviated letter differently
// from the rest of the path, making the two collapsed bits easy to spot.
enum DisplayPath {
  struct Parts {
    let tilde: String
    let abbrev: String
    let rest: String
  }

  static func shortenParts(_ path: String) -> Parts {
    let home = NSHomeDirectory()
    let rel = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    guard rel.hasPrefix("~/") else { return Parts(tilde: "", abbrev: "", rest: rel) }
    var comps = rel.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = comps.first, let letter = first.first else {
      return Parts(tilde: "~", abbrev: "", rest: "")
    }
    comps[0] = String(letter)
    let rest = comps.dropFirst().joined(separator: "/")
    return Parts(tilde: "~", abbrev: "/\(letter)", rest: rest.isEmpty ? "" : "/\(rest)")
  }
}

// one fixed color per known tag so the same tag always reads the same way
// at a glance.
enum StorageTagColor {
  private static let palette: [String: Color] = [
    "npm": .red,
    "pnpm": .yellow,
    "cargo": .orange,
    "rust": .orange,
    "go": .cyan,
    "pip": .mint,
    "python": .mint,
    "brew": .brown,
    "rattler": .purple,
    "playwright": .pink,
    "terragrunt": .indigo,
    "docker-image": .blue,
    "docker-volume": .gray,
    "docker-cache": .teal,
    "node": .green,
  ]
  private static let fallback: [Color] = [.teal, .indigo, .pink, .brown, .mint, .orange]

  // derived from the tag's utf8 byte sum so the same unlisted tag always
  // maps to the same fallback color.
  static func color(for tag: String) -> Color {
    if let known = palette[tag] { return known }
    let stable = tag.utf8.reduce(0) { $0 &+ Int($1) }
    return fallback[stable % fallback.count]
  }
}

@MainActor
private final class StorageRowState: ObservableObject {
  @Published var hover = false
  @Published var confirming = false
  @Published var clearHover = false
  @Published var copied = false
  private var copiedTask: Task<Void, Never>?

  func flashCopied() {
    copiedTask?.cancel()
    copied = true
    copiedTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      if Task.isCancelled { return }
      self?.copied = false
    }
  }
}

private struct StorageRow: View {
  let item: StorageItem
  let isClearing: Bool
  let didFail: Bool
  let onClear: () -> Void
  @StateObject private var state = StorageRowState()

  private var tagColor: Color { StorageTagColor.color(for: item.tag) }

  var body: some View {
    HStack(spacing: 10) {
      pathText
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(item.tag)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(tagColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tagColor.opacity(0.18)))
      Text(ByteFormat.string(item.sizeBytes))
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 66, alignment: .trailing)
      clearButton
    }
    .frame(height: 36)
    .padding(.horizontal, 8)
    .opacity(isClearing ? 0.5 : 1)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(state.hover ? Color.primary.opacity(0.06) : .clear)
    )
    .contentShape(Rectangle())
    .onHover { state.hover = $0 }
    .onTapGesture {
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(item.title, forType: .string)
      state.flashCopied()
    }
    .animation(.easeOut(duration: 0.15), value: isClearing)
  }

  private var pathText: Text {
    if state.copied {
      return Text("copied").foregroundStyle(.green)
    }
    let parts = DisplayPath.shortenParts(item.title)
    return Text(parts.tilde + parts.abbrev).foregroundStyle(.cyan)
      + Text(parts.rest).foregroundStyle(.primary)
  }

  private var clearButton: some View {
    Button {
      if didFail || state.confirming {
        onClear()
        state.confirming = false
      } else {
        state.confirming = true
      }
    } label: {
      HStack(spacing: 4) {
        if isClearing {
          ProgressView().controlSize(.mini)
        }
        Text(clearLabel)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(didFail || state.confirming ? .red : .secondary)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        Capsule().fill(
          (didFail || state.confirming ? Color.red : Color.primary)
            .opacity(state.clearHover ? 0.22 : 0.12))
      )
    }
    .buttonStyle(.plain)
    .disabled(isClearing)
    .help(didFail ? "Last attempt failed - click to retry" : "")
    .onHover { state.clearHover = $0 }
    .animation(.easeOut(duration: 0.1), value: state.clearHover)
    .onChange(of: state.hover) { _, hovering in
      if !hovering { state.confirming = false }
    }
  }

  private var clearLabel: String {
    if isClearing { return "Clearing..." }
    if didFail { return "Failed - retry?" }
    return state.confirming ? "Confirm?" : "Clear"
  }
}
