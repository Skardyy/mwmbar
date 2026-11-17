import Foundation

@MainActor
final class StorageController: ObservableObject {
  @Published private(set) var items: [StorageItem] = []
  @Published private(set) var isScanning = false
  @Published private(set) var hasScanned = false
  @Published private(set) var clearingIds: Set<String> = []
  @Published private(set) var failedIds: Set<String> = []

  // every probe is a du/mdfind/docker call, triggered only by this
  // explicit button press. rows land one at a time as StorageScanner
  // finds them.
  func check() {
    guard !isScanning else { return }
    isScanning = true
    hasScanned = true
    items = []
    Task.detached { [weak self] in
      for await item in StorageScanner.scan() {
        await MainActor.run {
          guard let self else { return }
          self.items.append(item)
          self.items.sort { $0.sizeBytes > $1.sizeBytes }
        }
      }
      await MainActor.run { self?.isScanning = false }
    }
  }

  func clear(_ item: StorageItem) {
    clearingIds.insert(item.id)
    failedIds.remove(item.id)
    Task.detached { [weak self] in
      let ok = StorageScanner.clear(item)
      await MainActor.run {
        guard let self else { return }
        self.clearingIds.remove(item.id)
        if ok {
          self.items.removeAll { $0.id == item.id }
        } else {
          self.failedIds.insert(item.id)
        }
      }
    }
  }
}
