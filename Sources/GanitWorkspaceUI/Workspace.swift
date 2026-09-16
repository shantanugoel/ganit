import AppKit
import GanitDocuments
import GanitEditorUI
import GanitEngine
import GanitFormatting

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
  /// The exchange rates every open and newly opened sheet evaluates with.
  public var currencyRates: CurrencyRates = .none {
    didSet {
      for sheet in sheets.values {
        sheet.editor.setCurrencyRates(currencyRates)
      }
      definitionsWindow?.editor.setCurrencyRates(currencyRates)
    }
  }
  /// The variables and units the definitions sheet defines, which every open
  /// and newly opened sheet evaluates with.
  public private(set) var definitions: SheetDefinitions = .none {
    didSet {
      for sheet in sheets.values {
        sheet.editor.setDefinitions(definitions)
      }
      definitionsDidChange?(definitions)
    }
  }
  /// Called when the definitions sheet's definitions change, so a sheet
  /// outside the library, such as Quick Ganit's buffer, can follow.
  public var definitionsDidChange: ((SheetDefinitions) -> Void)?
  /// Asks the reader's assistant about a line Ganit could not work out. Every
  /// open and newly opened sheet asks through it.
  public var askAssistant: ((String) async -> String?)? {
    didSet {
      for sheet in sheets.values {
        sheet.editor.askAssistant = askAssistant
      }
    }
  }
  /// Opens Help on a topic a sheet asked to show.
  public var openHelp: ((String) -> Void)? {
    didSet {
      for sheet in sheets.values {
        sheet.editor.openHelp = openHelp
      }
      definitionsWindow?.editor.openHelp = openHelp
    }
  }
  private let definitionsStore: TextDocumentStore?
  private(set) var definitionsWindow: DefinitionsWindowController?
  private var sheets: [UUID: OpenSheet] = [:]

  /// Reads the definitions sheet so the first sheet opened already evaluates
  /// with it, without opening its window.
  public init(library: SheetLibrary, definitions store: TextDocumentStore? = nil) throws {
    self.library = library
    definitionsStore = store
    try library.openScratch()
    if let text = store?.load(), !text.isEmpty {
      definitions = try SheetDefinitions(
        source: text,
        context: try SheetPreferences.standard.evaluationContext()
      )
    }
    Self.current = self
  }

  /// Opens the definitions sheet's window, creating it on first use.
  public func openDefinitions() throws {
    guard let store = definitionsStore else {
      return
    }
    if definitionsWindow == nil {
      let editor = SheetEditorViewController(
        text: store.load(),
        context: try SheetPreferences.standard.evaluationContext(currencyRates: currencyRates)
      )
      editor.definitionsDidChange = { [weak self] definitions in
        self?.definitions = definitions
      }
      editor.openHelp = openHelp
      definitionsWindow = DefinitionsWindowController(store: store, editor: editor)
    }
    definitionsWindow?.showWindow(nil)
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

  /// Brings the window already showing a sheet to the front, and opens one
  /// when no window shows it, so that opening the same sheet twice does not
  /// leave two windows on it.
  @discardableResult
  public func reveal(_ id: UUID) -> WorkspaceWindowController {
    guard let shown = windows.first(where: { $0.sheetID == id }) else {
      return openWindow(showing: id)
    }
    shown.showWindow(nil)
    return shown
  }

  /// Shows the scratch sheet, which every library has.
  @discardableResult
  public func openScratch() throws -> WorkspaceWindowController {
    reveal(try library.openScratch().id)
  }

  /// Brings an existing workspace window forward, or opens the most recent
  /// sheet when none is open, so the menu bar does not create a window every time.
  @discardableResult
  public func showCurrentWindow() throws -> WorkspaceWindowController {
    if let shown = windows.last {
      shown.window?.deminiaturize(nil)
      shown.showWindow(nil)
      return shown
    }
    return try openMostRecentSheet()
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
      context: try stored.metadata.preferences.evaluationContext(currencyRates: currencyRates),
      display: stored.metadata.preferences.display
    )
    editor.setDefinitions(definitions)
    editor.askAssistant = askAssistant
    editor.openHelp = openHelp
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

  /// Changes how a sheet writes its answers, keeping the choice with the sheet
  /// and rewriting what is on screen.
  func write(_ options: DisplayOptions, on id: UUID) throws {
    didChange(try library.update(id) { $0.preferences.display = options })
    guard let sheet = sheets[id] else {
      return
    }
    sheet.editor.writeAnswers(options)
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
