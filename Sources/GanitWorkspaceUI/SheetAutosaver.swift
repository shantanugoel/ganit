import Foundation
import GanitDocuments

/// Saves a sheet after edits settle, or immediately on request.
@MainActor
final class SheetAutosaver {
  static let settleDelay = Duration.seconds(1)

  private let library: SheetLibrary
  private let source: () -> String
  private let didSave: (SheetMetadata) -> Void
  private let didFail: (any Error) -> Void
  private(set) var metadata: SheetMetadata
  private(set) var hasUnsavedChanges = false
  private var pendingSave: Task<Void, Never>?

  init(
    library: SheetLibrary,
    metadata: SheetMetadata,
    source: @escaping () -> String,
    didSave: @escaping (SheetMetadata) -> Void,
    didFail: @escaping (any Error) -> Void
  ) {
    self.library = library
    self.metadata = metadata
    self.source = source
    self.didSave = didSave
    self.didFail = didFail
  }

  func sourceDidChange() {
    hasUnsavedChanges = true
    pendingSave?.cancel()
    pendingSave = Task { [weak self] in
      try? await Task.sleep(for: Self.settleDelay)
      guard !Task.isCancelled else {
        return
      }
      self?.saveNow()
    }
  }

  /// Saves unsaved changes now. A failed save keeps them unsaved, so the next
  /// edit or save request tries again.
  func saveNow() {
    pendingSave?.cancel()
    pendingSave = nil
    guard hasUnsavedChanges else {
      return
    }
    do {
      metadata = try library.save(source: source(), metadata: metadata)
      hasUnsavedChanges = false
      didSave(metadata)
    } catch {
      didFail(error)
    }
  }
}
