import AppKit
import GanitDocuments
import GanitEditorUI

/// A sheet open in the app: its editor, which owns the text and undo history,
/// and its autosaver. A sheet is shown in at most one window at a time.
@MainActor
final class OpenSheet {
  let editor: SheetEditorViewController
  let autosaver: SheetAutosaver
  weak var window: WorkspaceWindowController?

  init(editor: SheetEditorViewController, autosaver: SheetAutosaver) {
    self.editor = editor
    self.autosaver = autosaver
  }
}

/// The app's library windows and open sheets.
///
/// Open sheets persist while the app runs, so a sheet keeps its text, undo
/// history, and answers when a window switches away and back.
@MainActor
public final class Workspace {
  /// The workspace that restores windows at launch.
  public private(set) static weak var current: Workspace?

  public let library: SheetLibrary
  public private(set) var windows: [WorkspaceWindowController] = []
  private var sheets: [UUID: OpenSheet] = [:]

  public init(library: SheetLibrary) {
    self.library = library
    Self.current = self
  }

  /// Opens a window, optionally showing a sheet.
  @discardableResult
  public func openWindow(showing id: UUID?) -> WorkspaceWindowController {
    let controller = WorkspaceWindowController(workspace: self)
    windows.append(controller)
    if let id {
      controller.show(id)
    }
    controller.showWindow(nil)
    return controller
  }

  /// Opens a window with the most recently modified active sheet, or with a
  /// new sheet in an empty library.
  @discardableResult
  public func openMostRecentSheet() throws -> WorkspaceWindowController {
    guard let recent = try library.index.summaries().first(where: { $0.state == .active }) else {
      return try openNewSheet(source: "")
    }
    return openWindow(showing: recent.id)
  }

  /// Saves text as a new sheet, such as a promoted Quick Ganit buffer, and
  /// opens it in a window.
  @discardableResult
  public func openNewSheet(source: String) throws -> WorkspaceWindowController {
    let metadata = try library.save(
      source: source, metadata: library.create(preferences: .standard))
    return openWindow(showing: metadata.id)
  }

  /// Imports a `.ganit` package or text file and returns the new sheet's ID.
  public func importSheet(from url: URL) throws -> UUID {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let metadata = try library.importSheet(
      from: url,
      preferences: SheetPreferences.standard
    )
    for window in windows {
      window.libraryDidChange()
    }
    return metadata.id
  }

  /// Saves every open sheet's unsaved edits.
  public func saveAll() {
    for sheet in sheets.values {
      sheet.autosaver.saveNow()
    }
  }

  func windowWillClose(_ controller: WorkspaceWindowController) {
    windows.removeAll { $0 === controller }
  }

  /// The open sheet for an ID, opening it from the library if needed.
  func sheet(_ id: UUID) throws -> OpenSheet {
    if let sheet = sheets[id] {
      return sheet
    }
    let stored = try library.store.load(id: id)
    let editor = SheetEditorViewController(
      text: stored.source,
      context: try stored.metadata.preferences.evaluationContext()
    )
    editor.textView.isEditable = stored.metadata.state != .trashed
    let autosaver = SheetAutosaver(
      library: library,
      metadata: stored.metadata,
      source: { [editor] in editor.sheet.text },
      didSave: { [weak self] metadata in self?.didChange(metadata) },
      didFail: { error in NSApplication.shared.presentError(error) }
    )
    editor.sourceDidChange = { [weak autosaver] in autosaver?.sourceDidChange() }
    let sheet = OpenSheet(editor: editor, autosaver: autosaver)
    sheets[id] = sheet
    return sheet
  }

  /// Changes a sheet's metadata as one undoable action. Undo returns the
  /// title, favorite flag, folder, and state to their previous values.
  func organize(
    _ id: UUID,
    named actionName: String,
    undoManager: UndoManager?,
    _ change: () throws -> SheetMetadata
  ) throws {
    sheets[id]?.autosaver.saveNow()
    let before = try library.store.load(id: id).metadata
    didChange(try change())
    undoManager?.registerUndo(withTarget: self) { workspace in
      try? workspace.organize(id, named: actionName, undoManager: undoManager) {
        try workspace.library.update(id) {
          $0.title = before.title
          $0.hasCustomTitle = before.hasCustomTitle
          $0.isFavorite = before.isFavorite
          $0.folderID = before.folderID
          $0.state = before.state
        }
      }
    }
    undoManager?.setActionName(actionName)
  }

  /// Closes a deleted sheet everywhere, discarding its editor.
  func discard(_ id: UUID) {
    sheets[id]?.window?.showFirstListedSheet(excluding: id)
    sheets[id] = nil
  }

  /// Applies a sheet's saved or changed metadata to its open sheet and every
  /// window.
  private func didChange(_ metadata: SheetMetadata) {
    if let sheet = sheets[metadata.id] {
      sheet.autosaver.adopt(metadata)
      sheet.editor.textView.isEditable = metadata.state != .trashed
    }
    for window in windows {
      window.libraryDidChange()
    }
  }
}

/// Recreates workspace windows during state restoration.
public final class WorkspaceRestoration: NSObject, NSWindowRestoration {
  public static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    MainActor.assumeIsolated {
      completionHandler(Workspace.current?.openWindow(showing: nil).window, nil)
    }
  }
}
