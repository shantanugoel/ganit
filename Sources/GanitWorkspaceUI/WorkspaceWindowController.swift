import AppKit
import GanitDocuments
import GanitEditorUI
import GanitEngine

/// A library window: the sidebar of collections and sheets beside the open
/// sheet's editor, which saves as it changes.
@MainActor
public final class WorkspaceWindowController: NSWindowController, WorkspaceCommands,
  NSMenuItemValidation
{
  /// Preferences for new sheets until sheet preference settings exist.
  public nonisolated static let newSheetPreferences = SheetPreferences(
    localeIdentifier: "en-US",
    angleMode: .radians,
    significantDecimalDigits: 15
  )

  public private(set) var editor: SheetEditorViewController?
  let sidebar: SidebarViewController
  private let library: SheetLibrary
  private let splitViewController = NSSplitViewController()
  private let content = NSViewController()
  private let searchItem = NSSearchToolbarItem(itemIdentifier: .searchSheets)
  private var autosaver: SheetAutosaver?

  public var sheetID: UUID? {
    autosaver?.metadata.id
  }

  public init(library: SheetLibrary, sheet: StoredSheet?) throws {
    self.library = library
    sidebar = SidebarViewController(library: library)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.contentMinSize = NSSize(width: 640, height: 400)
    window.tabbingMode = .preferred
    window.isReleasedWhenClosed = false
    super.init(window: window)

    content.view = NSView()
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = true
    sidebarItem.minimumThickness = 200
    splitViewController.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: content)]
    window.contentViewController = splitViewController

    let toolbar = NSToolbar(identifier: "workspace")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    searchItem.searchField.target = self
    searchItem.searchField.action = #selector(searchFieldChanged(_:))

    sidebar.didSelectSheet = { [weak self] id in
      guard self?.sheetID != id else {
        return
      }
      self?.open(id)
    }
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(saveNow(_:)), name: name, object: window)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveNow(_:)),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
    if let sheet {
      try show(sheet)
    } else {
      updateTitle()
    }
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  // MARK: Showing sheets

  /// Saves the open sheet, then opens another in the editor.
  func show(_ sheet: StoredSheet) throws {
    saveNow(nil)
    let editor = SheetEditorViewController(
      text: sheet.source,
      context: try Self.context(for: sheet.metadata.preferences)
    )
    editor.textView.isEditable = sheet.metadata.state != .trashed
    let autosaver = SheetAutosaver(
      library: library,
      metadata: sheet.metadata,
      source: { [editor] in editor.sheet.text },
      didSave: { [weak self] _ in
        self?.updateTitle()
        self?.sidebar.reload()
      },
      didFail: { [weak window] error in window?.presentError(error) }
    )
    editor.sourceDidChange = { [weak autosaver] in autosaver?.sourceDidChange() }
    setEditor(editor, autosaver: autosaver)
    sidebar.select(sheet: sheet.metadata.id)
    window?.makeFirstResponder(editor.textView)
  }

  private func open(_ id: UUID) {
    do {
      try show(library.store.load(id: id))
    } catch {
      window?.presentError(error)
    }
  }

  private func setEditor(_ editor: SheetEditorViewController?, autosaver: SheetAutosaver?) {
    self.editor?.view.removeFromSuperview()
    self.editor?.removeFromParent()
    self.editor = editor
    self.autosaver = autosaver
    if let editor {
      content.addChild(editor)
      editor.view.frame = content.view.bounds
      editor.view.autoresizingMask = [.width, .height]
      content.view.addSubview(editor.view)
    }
    updateTitle()
  }

  /// Opens the first sheet listed, or clears the editor when none is.
  private func showFirstListedSheet() {
    sidebar.reload()
    if let first = sidebar.sheets.first {
      open(first.id)
    } else {
      setEditor(nil, autosaver: nil)
    }
  }

  private func updateTitle() {
    guard let metadata = autosaver?.metadata else {
      window?.title = "Ganit"
      return
    }
    window?.title =
      metadata.title.isEmpty ? localized("sheet.untitled", "Untitled") : metadata.title
  }

  // MARK: Commands

  /// Saves unsaved edits immediately.
  @objc public func saveNow(_ sender: Any?) {
    autosaver?.saveNow()
  }

  /// Creates a sheet in the selected folder and opens it.
  @objc public func newSheet(_ sender: Any?) {
    perform {
      var metadata = try library.create(preferences: Self.newSheetPreferences)
      if case .folder(let folder) = sidebar.collection {
        metadata = try library.update(metadata.id) { $0.folderID = folder }
      } else if ![.all, .recent].contains(sidebar.collection) {
        sidebar.show(.all)
      }
      sidebar.reload()
      try show(library.store.load(id: metadata.id))
    }
  }

  @objc public func newFolder(_ sender: Any?) {
    ask(localized("folder.new", "New Folder"), initial: "") { name in
      let folder = try self.library.createFolder(named: name)
      self.sidebar.reload()
      self.sidebar.show(.folder(folder.id))
    }
  }

  @objc public func renameSheet(_ sender: Any?) {
    guard let sheet = sidebar.targetSheet else {
      return
    }
    ask(localized("sheet.rename", "Rename Sheet"), initial: sheet.title, allowsEmpty: true) {
      title in
      self.saveNow(nil)
      let metadata = try self.library.rename(sheet.id, to: title)
      self.refresh(metadata)
    }
  }

  @objc public func duplicateSheet(_ sender: Any?) {
    guard let sheet = sidebar.targetSheet else {
      return
    }
    perform {
      saveNow(nil)
      let copy = try library.duplicate(sheet.id)
      sidebar.reload()
      try show(library.store.load(id: copy.id))
    }
  }

  @objc public func toggleFavorite(_ sender: Any?) {
    guard let sheet = sidebar.targetSheet else {
      return
    }
    perform { refresh(try library.update(sheet.id) { $0.isFavorite.toggle() }) }
  }

  @objc public func moveSheetToFolder(_ sender: Any?) {
    guard let sheet = sidebar.targetSheet else {
      return
    }
    let folder = (sender as? NSMenuItem)?.representedObject as? UUID
    perform { refresh(try library.update(sheet.id) { $0.folderID = folder }) }
  }

  @objc public func archiveSheet(_ sender: Any?) {
    setState(.archived)
  }

  @objc public func moveSheetToTrash(_ sender: Any?) {
    setState(.trashed)
  }

  /// Returns an archived or trashed sheet to the library.
  @objc public func restoreSheet(_ sender: Any?) {
    setState(.active)
  }

  @objc public func deleteSheetImmediately(_ sender: Any?) {
    guard let sheet = sidebar.targetSheet, sheet.state == .trashed else {
      return
    }
    confirm(
      localized("sheet.deleteImmediately", "Delete this sheet immediately?"),
      localized(
        "sheet.deleteImmediately.detail",
        "The sheet and its backups are deleted. You can't undo this.")
    ) {
      if self.sheetID == sheet.id {
        self.setEditor(nil, autosaver: nil)
      }
      try self.library.deletePermanently(sheet.id)
      self.showFirstListedSheet()
    }
  }

  @objc public func emptyTrash(_ sender: Any?) {
    confirm(
      localized("trash.empty", "Empty the Trash?"),
      localized(
        "trash.empty.detail",
        "Every sheet in the Trash and its backups are deleted. You can't undo this.")
    ) {
      if self.autosaver?.metadata.state == .trashed {
        self.setEditor(nil, autosaver: nil)
      }
      try self.library.emptyTrash()
      self.showFirstListedSheet()
    }
  }

  @objc public func renameFolder(_ sender: Any?) {
    guard let folder = sidebar.targetFolder else {
      return
    }
    ask(localized("folder.rename", "Rename Folder"), initial: folder.name) { name in
      try self.library.renameFolder(folder.id, to: name)
      self.sidebar.reload()
    }
  }

  @objc public func deleteFolder(_ sender: Any?) {
    guard let folder = sidebar.targetFolder else {
      return
    }
    perform {
      try library.deleteFolder(folder.id)
      sidebar.reload()
    }
  }

  @objc public func searchSheets(_ sender: Any?) {
    window?.makeFirstResponder(searchItem.searchField)
  }

  @objc private func searchFieldChanged(_ sender: NSSearchField) {
    sidebar.search = sender.stringValue
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let sheet = sidebar.targetSheet
    switch menuItem.action {
    case #selector(renameSheet(_:)), #selector(duplicateSheet(_:)),
      #selector(moveSheetToFolder(_:)),
      #selector(archiveSheet(_:)):
      return sheet?.state == .active
    case #selector(toggleFavorite(_:)):
      menuItem.title =
        sheet?.isFavorite == true
        ? localized("menu.removeFavorite", "Remove from Favorites")
        : localized("menu.addFavorite", "Add to Favorites")
      return sheet?.state == .active
    case #selector(moveSheetToTrash(_:)):
      return sheet != nil && sheet?.state != .trashed
    case #selector(restoreSheet(_:)):
      return sheet != nil && sheet?.state != .active
    case #selector(deleteSheetImmediately(_:)):
      return sheet?.state == .trashed
    case #selector(renameFolder(_:)), #selector(deleteFolder(_:)):
      return sidebar.targetFolder != nil
    case #selector(restorePreviousVersion(_:)):
      return autosaver != nil
    default:
      return true
    }
  }

  private func setState(_ state: SheetState) {
    guard let sheet = sidebar.targetSheet else {
      return
    }
    perform {
      saveNow(nil)
      try library.update(sheet.id) { $0.state = state }
      if sheetID == sheet.id {
        showFirstListedSheet()
      } else {
        sidebar.reload()
      }
    }
  }

  /// Updates the open sheet's metadata when it changed, and the sidebar.
  private func refresh(_ metadata: SheetMetadata) {
    if sheetID == metadata.id {
      open(metadata.id)
    }
    sidebar.reload()
  }

  private func perform(_ action: () throws -> Void) {
    do {
      try action()
    } catch {
      window?.presentError(error)
    }
  }

  private func ask(
    _ title: String,
    initial: String,
    allowsEmpty: Bool = false,
    _ action: @escaping (String) throws -> Void
  ) {
    guard let window else {
      return
    }
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: localized("alert.ok", "OK"))
    alert.addButton(withTitle: localized("restore.cancel", "Cancel"))
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      let text = field.stringValue.trimmingCharacters(in: .whitespaces)
      guard response == .alertFirstButtonReturn, allowsEmpty || !text.isEmpty else {
        return
      }
      self?.perform { try action(text) }
    }
  }

  private func confirm(_ message: String, _ detail: String, _ action: @escaping () throws -> Void) {
    guard let window else {
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: localized("alert.delete", "Delete")).hasDestructiveAction = true
    alert.addButton(withTitle: localized("restore.cancel", "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      self?.perform(action)
    }
  }

  // MARK: Restore Previous Version

  /// Offers the open sheet's daily backups and restores the chosen one.
  @objc public func restorePreviousVersion(_ sender: Any?) {
    guard let window, let sheetID else {
      return
    }
    saveNow(nil)
    let backups: [SheetBackup]
    do {
      backups = try library.backups(of: sheetID)
    } catch {
      window.presentError(error)
      return
    }
    let alert = NSAlert()
    guard !backups.isEmpty else {
      alert.messageText = localized("restore.none", "There are no previous versions of this sheet.")
      alert.beginSheetModal(for: window)
      return
    }
    alert.messageText = localized("restore.title", "Restore a previous version?")
    alert.informativeText = localized(
      "restore.message",
      "The sheet is replaced with its contents from before the first change on the chosen day. You can undo this."
    )
    let days = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
    days.addItems(withTitles: backups.map(\.day))
    alert.accessoryView = days
    alert.addButton(withTitle: localized("restore.confirm", "Restore"))
    alert.addButton(withTitle: localized("restore.cancel", "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      self?.restore(backups[days.indexOfSelectedItem])
    }
  }

  /// Replaces the editor's text with a backup as one undoable edit, which is
  /// then saved.
  func restore(_ backup: SheetBackup) {
    guard let textView = editor?.textView else {
      return
    }
    perform {
      let source = try library.load(backup).source
      textView.insertText(
        source, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
      )
      textView.undoManager?.setActionName(localized("restore.undo", "Restore Previous Version"))
      saveNow(nil)
    }
  }

  private static func context(for preferences: SheetPreferences) throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: preferences.localeIdentifier,
      // English grammar with `en-US` separators is the only lexing syntax so far.
      lexingConfiguration: .englishUnitedStates,
      angleMode: preferences.angleMode,
      precision: PrecisionContext(significantDecimalDigits: preferences.significantDecimalDigits),
      now: Date(),
      calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: TimeZone.current.identifier) ?? .gmt
    )
  }
}

extension NSToolbarItem.Identifier {
  static let newSheet = NSToolbarItem.Identifier("newSheet")
  static let searchSheets = NSToolbarItem.Identifier("searchSheets")
}

extension WorkspaceWindowController: NSToolbarDelegate {
  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .newSheet, .flexibleSpace, .searchSheets]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar) + [.space]
  }

  public func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch identifier {
    case .newSheet:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = localized("menu.newSheet", "New Sheet")
      item.image = NSImage(
        systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
      item.action = #selector(newSheet(_:))
      item.target = self
      return item
    case .searchSheets:
      searchItem.label = localized("menu.searchSheets", "Search Sheets")
      return searchItem
    default:
      return nil
    }
  }
}
