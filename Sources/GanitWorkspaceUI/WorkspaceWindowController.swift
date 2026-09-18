import AppKit
import GanitDocuments
import GanitEditorUI
import GanitFormatting
import UniformTypeIdentifiers

/// A library window: the sidebar of collections and sheets beside the open
/// sheet's editor.
@MainActor
public final class WorkspaceWindowController: NSWindowController, WorkspaceCommands,
  NSMenuItemValidation, NSWindowDelegate
{
  let sidebar: SidebarViewController
  private unowned let workspace: Workspace
  private let splitViewController = NSSplitViewController()
  private let content = NSViewController()
  private let searchItem = NSSearchToolbarItem(itemIdentifier: .searchSheets)
  private var sheet: OpenSheet?

  public var editor: SheetEditorViewController? {
    sheet?.editor
  }

  public var sheetID: UUID? {
    sheet?.autosaver.metadata.id
  }

  private var library: SheetLibrary {
    workspace.library
  }

  init(workspace: Workspace) {
    self.workspace = workspace
    sidebar = SidebarViewController(library: workspace.library)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.contentMinSize = NSSize(width: 640, height: 400)
    window.tabbingMode = .preferred
    window.collectionBehavior = [.fullScreenPrimary]
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("workspace")
    window.isRestorable = true
    window.restorationClass = WorkspaceRestoration.self
    super.init(window: window)
    window.delegate = self

    content.view = NSView()
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = true
    // A sheet title and a date are all the sidebar lists, so it stays a
    // narrow index of the library rather than a second half of the window.
    sidebarItem.minimumThickness = 150
    sidebarItem.maximumThickness = 280
    splitViewController.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: content)]
    // The name changed with the narrower default, so a width saved by the
    // wide sidebar does not outlive it.
    splitViewController.splitView.autosaveName = "WorkspaceSidebar"
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
      self?.show(id)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveNow(_:)),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
    updateTitle()
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  // MARK: Showing sheets

  /// Shows a sheet in this window, or brings forward the window already
  /// showing it.
  func show(_ id: UUID) {
    let previous = sheetID
    do {
      let next = try workspace.sheet(id)
      if let other = next.window, other !== self {
        other.showWindow(nil)
        sidebar.select(sheet: sheetID)
        return
      }
      saveNow(nil)
      sheet?.window = nil
      sheet?.editor.view.removeFromSuperview()
      sheet?.editor.removeFromParent()
      sheet = next
      next.window = self
      content.addChild(next.editor)
      next.editor.view.frame = content.view.bounds
      next.editor.view.autoresizingMask = [.width, .height]
      content.view.addSubview(next.editor.view)
      sidebar.select(sheet: id)
      window?.makeFirstResponder(next.editor.textView)
      discardIfUntouched(previous)
    } catch {
      window?.presentError(error)
    }
    updateTitle()
    window?.invalidateRestorableState()
  }

  /// Shows the first listed sheet other than `excluded`, or clears the
  /// editor.
  func showFirstListedSheet(excluding excluded: UUID? = nil) {
    sidebar.reload()
    if let first = sidebar.sheets.first(where: { $0.id != excluded && $0.id != sheetID }) {
      show(first.id)
    } else {
      sheet?.window = nil
      sheet?.editor.view.removeFromSuperview()
      sheet?.editor.removeFromParent()
      sheet = nil
      updateTitle()
    }
  }

  /// Refreshes the sidebar and title after a sheet was saved or organized.
  func libraryDidChange() {
    sidebar.reload()
    updateTitle()
    if let sheetID, !sidebar.sheets.contains(where: { $0.id == sheetID }),
      let metadata = sheet?.autosaver.metadata, metadata.state != .active
    {
      // The open sheet left the listed collection, as when it was archived here.
      if sidebar.collection != .archive && sidebar.collection != .trash {
        showFirstListedSheet(excluding: sheetID)
      }
    }
  }

  private func updateTitle() {
    guard let metadata = sheet?.autosaver.metadata else {
      window?.title = "Ganit"
      return
    }
    window?.title =
      metadata.title.isEmpty ? localized("sheet.untitled", "Untitled") : metadata.title
  }

  public func windowDidResignKey(_ notification: Notification) {
    saveNow(nil)
  }

  public func windowWillClose(_ notification: Notification) {
    saveNow(nil)
    let closing = sheetID
    sheet?.window = nil
    workspace.windowWillClose(self)
    discardIfUntouched(closing)
  }

  /// Removes a sheet nothing was written in and nobody named, so ⌘N then a
  /// change of mind leaves no empty Untitled behind. Scratch always stays, as
  /// does a sheet open in another window.
  private func discardIfUntouched(_ id: UUID?) {
    guard let id, id != sheetID, id != SheetLibrary.scratchID,
      workspace.windows.allSatisfy({ $0.sheetID != id }),
      let stored = try? library.store.load(id: id),
      stored.metadata.title.isEmpty, !stored.metadata.isFavorite,
      stored.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }
    try? library.deletePermanently(id)
    sidebar.reload()
  }

  // MARK: Restoration

  private struct RestorableState: Codable {
    var sheetID: UUID?
    var collection: SheetCollection
    var search: String
    var selection: [Int]
    var scrollOffset: Double
    var isSidebarCollapsed: Bool
  }

  private static let restorableStateKey = "workspaceWindow"

  public func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    let textView = editor?.textView
    let restorable = RestorableState(
      sheetID: sheetID,
      collection: sidebar.collection,
      search: sidebar.search,
      selection: textView.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? [],
      scrollOffset: Double(textView?.enclosingScrollView?.contentView.bounds.minY ?? 0),
      isSidebarCollapsed: splitViewController.splitViewItems[0].isCollapsed
    )
    if let data = try? JSONEncoder().encode(restorable) {
      state.encode(data, forKey: Self.restorableStateKey)
    }
  }

  public func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
    guard
      let data = state.decodeObject(of: NSData.self, forKey: Self.restorableStateKey) as Data?,
      let restorable = try? JSONDecoder().decode(RestorableState.self, from: data)
    else {
      return
    }
    sidebar.show(restorable.collection)
    sidebar.search = restorable.search
    searchItem.searchField.stringValue = restorable.search
    splitViewController.splitViewItems[0].isCollapsed = restorable.isSidebarCollapsed
    guard let id = restorable.sheetID, (try? library.store.load(id: id)) != nil else {
      showFirstListedSheet()
      return
    }
    show(id)
    guard let textView = editor?.textView, restorable.selection.count == 2 else {
      return
    }
    let length = (textView.string as NSString).length
    let location = min(restorable.selection[0], length)
    textView.setSelectedRange(
      NSRange(location: location, length: min(restorable.selection[1], length - location))
    )
    textView.scroll(NSPoint(x: 0, y: restorable.scrollOffset))
  }

  // MARK: Commands

  /// Saves unsaved edits immediately.
  @objc public func saveNow(_ sender: Any?) {
    sheet?.autosaver.saveNow()
  }

  /// Creates a sheet in the selected folder and shows it.
  @objc public func newSheet(_ sender: Any?) {
    perform {
      var metadata = try library.create(preferences: SheetPreferences.newSheet())
      if case .folder(let folder) = sidebar.collection {
        metadata = try library.update(metadata.id) { $0.folderID = folder }
      } else if ![.all, .recent].contains(sidebar.collection) {
        sidebar.show(.all)
      }
      sidebar.reload()
      show(metadata.id)
    }
  }

  /// Opens the target sheet in a new window.
  @objc public func openInNewWindow(_ sender: Any?) {
    guard let target = sidebar.targetSheet?.id ?? sheetID else {
      return
    }
    if let other = (try? workspace.sheet(target))?.window {
      other.showWindow(nil)
      return
    }
    workspace.openWindow(showing: target)
  }

  /// Imports chosen `.ganit` packages and text files as new sheets and shows
  /// the last one.
  @objc public func importSheets(_ sender: Any?) {
    guard let window else {
      return
    }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.ganitSheet, .plainText]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self else {
        return
      }
      perform {
        let imported = try panel.urls.map {
          try self.workspace.importSheet(from: $0)
        }
        if let last = imported.last {
          sidebar.show(.all)
          show(last)
        }
      }
    }
  }

  /// Exports the open sheet as a `.ganit` package or plain text.
  @objc public func exportSheet(_ sender: Any?) {
    guard let window, let sheetID, let title = sheet?.autosaver.metadata.title else {
      return
    }
    saveNow(nil)
    let panel = NSSavePanel()
    let formats = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
    formats.addItems(withTitles: [
      localized("export.ganit", "Ganit Sheet"), localized("export.text", "Plain Text"),
      localized("export.pdf", "PDF"), localized("export.csv", "CSV"),
      localized("export.html", "HTML"),
    ])
    let types: [UTType] = [.ganitSheet, .plainText, .pdf, .commaSeparatedText, .html]
    panel.allowedContentTypes = [types[0]]
    panel.accessoryView = formats
    panel.nameFieldStringValue = title.isEmpty ? localized("sheet.untitled", "Untitled") : title
    let observer = FormatObserver(panel: panel, types: types)
    formats.target = observer
    formats.action = #selector(FormatObserver.formatChanged(_:))
    panel.beginSheetModal(for: window) { [weak self] response in
      withExtendedLifetime(observer) {}
      guard response == .OK, let url = panel.url, let editor = self?.editor else {
        return
      }
      let type = types[formats.indexOfSelectedItem]
      Task { @MainActor in
        let lines = await editor.exportedLines()
        let name = url.deletingPathExtension().lastPathComponent
        self?.perform {
          switch type {
          case .pdf:
            try SheetDocumentRenderer.pdf(lines, title: name).write(to: url, options: .atomic)
          case .commaSeparatedText:
            try Data(SheetDocumentRenderer.csv(lines).utf8).write(to: url, options: .atomic)
          case .html:
            try Data(SheetDocumentRenderer.html(lines, title: name).utf8).write(
              to: url, options: .atomic)
          default:
            let pdf = try SheetDocumentRenderer.pdf(lines, title: name)
            let quickLook =
              type == .ganitSheet
              ? SheetDocumentRenderer.thumbnail(ofPDF: pdf).map {
                QuickLookPreview(pdf: pdf, thumbnailPNG: $0)
              } : nil
            try self?.library.exportSheet(sheetID, to: url, quickLook: quickLook)
          }
        }
      }
    }
  }

  /// Prints the sheet's source beside its answers.
  @objc public func printSheet(_ sender: Any?) {
    guard let window, let editor else {
      return
    }
    Task { @MainActor in
      let printInfo = SheetDocumentRenderer.printInfo()
      let view = SheetDocumentRenderer.printableView(
        await editor.exportedLines(), printInfo: printInfo)
      let operation = NSPrintOperation(view: view, printInfo: printInfo)
      operation.jobTitle = window.title
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
    guard let target = sidebar.targetSheet else {
      return
    }
    ask(localized("sheet.rename", "Rename Sheet"), initial: target.title, allowsEmpty: true) {
      title in
      try self.organize(target.id, localized("menu.renameSheet", "Rename…")) {
        try self.library.rename(target.id, to: title)
      }
    }
  }

  @objc public func duplicateSheet(_ sender: Any?) {
    guard let target = sidebar.targetSheet else {
      return
    }
    perform {
      workspace.saveAll()
      let copy = try library.duplicate(target.id)
      sidebar.reload()
      show(copy.id)
    }
  }

  @objc public func toggleFavorite(_ sender: Any?) {
    guard let target = sidebar.targetSheet else {
      return
    }
    let name =
      target.isFavorite
      ? localized("menu.removeFavorite", "Remove from Favorites")
      : localized("menu.addFavorite", "Add to Favorites")
    perform {
      try organize(target.id, name) { try library.update(target.id) { $0.isFavorite.toggle() } }
    }
  }

  @objc public func moveSheetToFolder(_ sender: Any?) {
    guard let target = sidebar.targetSheet else {
      return
    }
    let folder = (sender as? NSMenuItem)?.representedObject as? UUID
    perform {
      try organize(target.id, localized("menu.moveToFolder", "Move to Folder")) {
        try library.update(target.id) { $0.folderID = folder }
      }
    }
  }

  @objc public func archiveSheet(_ sender: Any?) {
    setState(.archived, localized("menu.archiveSheet", "Archive"))
  }

  @objc public func moveSheetToTrash(_ sender: Any?) {
    setState(.trashed, localized("menu.moveToTrash", "Move to Trash"))
  }

  /// Returns an archived or trashed sheet to the library.
  @objc public func restoreSheet(_ sender: Any?) {
    setState(.active, localized("menu.putBack", "Put Back"))
  }

  @objc public func deleteSheetImmediately(_ sender: Any?) {
    guard let target = sidebar.targetSheet, target.state == .trashed else {
      return
    }
    confirm(
      localized("sheet.deleteImmediately", "Delete this sheet immediately?"),
      localized(
        "sheet.deleteImmediately.detail",
        "The sheet and its backups are deleted. You can't undo this.")
    ) {
      self.workspace.discard(target.id)
      try self.library.deletePermanently(target.id)
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
      for summary in try self.library.index.summaries() where summary.state == .trashed {
        self.workspace.discard(summary.id)
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
      workspace.saveAll()
      try library.deleteFolder(folder.id)
      sidebar.reload()
    }
  }

  @objc public func searchSheets(_ sender: Any?) {
    window?.makeFirstResponder(searchItem.searchField)
  }

  @objc private func searchFieldChanged(_ sender: NSSearchField) {
    sidebar.search = sender.stringValue
    window?.invalidateRestorableState()
  }

  // MARK: How Answers Are Written

  /// How the open sheet writes its answers.
  private var displayOptions: DisplayOptions? {
    sheet?.autosaver.metadata.preferences.display
  }

  @objc public func setNumberFormat(_ sender: Any?) {
    guard let tag = (sender as? NSMenuItem)?.tag, var options = displayOptions else {
      return
    }
    options.numbers = NumberFormatMenu.display(forTag: tag)
    write(options)
  }

  @objc public func toggleDigitGrouping(_ sender: Any?) {
    guard var options = displayOptions else {
      return
    }
    options.groupsDigits.toggle()
    write(options)
  }

  @objc public func toggleDegrees(_ sender: Any?) {
    guard let id = sheetID, let mode = sheet?.autosaver.metadata.preferences.angleMode else {
      return
    }
    perform { try workspace.write(mode == .degrees ? .radians : .degrees, on: id) }
  }

  @objc public func toggleDecimalComma(_ sender: Any?) {
    guard let id = sheetID, let preferences = sheet?.autosaver.metadata.preferences else {
      return
    }
    perform { try workspace.write(usesDecimalComma: !preferences.usesDecimalComma, on: id) }
  }

  @objc public func toggleLakhGrouping(_ sender: Any?) {
    guard var options = displayOptions else {
      return
    }
    options.groupsInLakhs.toggle()
    write(options)
  }

  @objc public func toggleMarkdownMode(_ sender: Any?) {
    let id = sidebar.targetSheet?.id ?? sheetID
    guard let id,
      var options = (try? library.store.load(id: id))?.metadata.preferences.display
    else {
      return
    }
    options.writesAnswersInline.toggle()
    perform { try workspace.write(options, on: id) }
  }

  @objc public func setDollarCurrency(_ sender: Any?) {
    guard let code = (sender as? NSMenuItem)?.representedObject as? String else {
      return
    }
    let id = sidebar.targetSheet?.id ?? sheetID
    guard let id,
      var options = (try? library.store.load(id: id))?.metadata.preferences.display
    else {
      return
    }
    options.dollarCurrency = code
    perform { try workspace.write(options, on: id) }
  }

  @objc public func toggleAnswerSeparator(_ sender: Any?) {
    guard var options = displayOptions else {
      return
    }
    options.showsAnswerSeparator.toggle()
    write(options)
  }

  private func write(_ options: DisplayOptions) {
    guard let id = sheetID else {
      return
    }
    perform { try workspace.write(options, on: id) }
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let target = sidebar.targetSheet
    switch menuItem.action {
    case #selector(setNumberFormat(_:)):
      menuItem.state =
        displayOptions?.numbers == NumberFormatMenu.display(forTag: menuItem.tag) ? .on : .off
      return displayOptions != nil
    case #selector(toggleDigitGrouping(_:)):
      menuItem.state = displayOptions?.groupsDigits == true ? .on : .off
      return displayOptions != nil
    case #selector(toggleDegrees(_:)):
      menuItem.state =
        sheet?.autosaver.metadata.preferences.angleMode == .degrees ? .on : .off
      return sheetID != nil
    case #selector(toggleDecimalComma(_:)):
      menuItem.state =
        sheet?.autosaver.metadata.preferences.usesDecimalComma == true ? .on : .off
      return sheetID != nil
    case #selector(toggleLakhGrouping(_:)):
      menuItem.state = displayOptions?.groupsInLakhs == true ? .on : .off
      return displayOptions?.groupsDigits == true
    case #selector(toggleMarkdownMode(_:)):
      menuItem.state =
        (target?.isMarkdown ?? displayOptions?.writesAnswersInline) == true ? .on : .off
      return target != nil || displayOptions != nil
    case #selector(setDollarCurrency(_:)):
      let code = menuItem.representedObject as? String
      let current =
        (try? target.flatMap { try library.store.load(id: $0.id) })?
        .metadata.preferences.display.dollarCurrency ?? displayOptions?.dollarCurrency
      menuItem.state = code == current ? .on : .off
      return target != nil || displayOptions != nil
    case #selector(toggleAnswerSeparator(_:)):
      menuItem.state = displayOptions?.showsAnswerSeparator == true ? .on : .off
      // Answers written inline leave nothing for the rule to separate.
      return displayOptions?.writesAnswersInline == false
    case #selector(duplicateSheet(_:)), #selector(moveSheetToFolder(_:)),
      #selector(openInNewWindow(_:)):
      return target?.state == .active
    // The scratch sheet is the one a person can always reach for, so it keeps
    // its name and cannot be put away.
    case #selector(renameSheet(_:)), #selector(archiveSheet(_:)):
      return target?.state == .active && target?.id != SheetLibrary.scratchID
    case #selector(toggleFavorite(_:)):
      menuItem.title =
        target?.isFavorite == true
        ? localized("menu.removeFavorite", "Remove from Favorites")
        : localized("menu.addFavorite", "Add to Favorites")
      return target?.state == .active
    case #selector(moveSheetToTrash(_:)):
      return target != nil && target?.state != .trashed && target?.id != SheetLibrary.scratchID
    case #selector(restoreSheet(_:)):
      return target != nil && target?.state != .active
    case #selector(deleteSheetImmediately(_:)):
      return target?.state == .trashed
    case #selector(renameFolder(_:)), #selector(deleteFolder(_:)):
      return sidebar.targetFolder != nil
    case #selector(restorePreviousVersion(_:)):
      return sheet != nil
    default:
      return true
    }
  }

  private func setState(_ state: SheetState, _ actionName: String) {
    guard let target = sidebar.targetSheet else {
      return
    }
    perform {
      try organize(target.id, actionName) { try library.update(target.id) { $0.state = state } }
    }
  }

  private func organize(_ id: UUID, _ actionName: String, _ change: () throws -> SheetMetadata)
    throws
  {
    try workspace.organize(id, named: actionName, undoManager: window?.undoManager, change)
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

  private func confirm(
    _ message: String, _ detail: String, _ action: @escaping () throws -> Void
  ) {
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
        systemSymbolName: VisualStyle.Symbol.newSheet, accessibilityDescription: item.label)
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

extension UTType {
  /// A `.ganit` sheet package.
  static let ganitSheet =
    UTType(
      filenameExtension: SheetExchange.packageExtension,
      conformingTo: .package
    ) ?? .package
}

/// Switches a save panel's file type with its format pop-up.
@MainActor
private final class FormatObserver: NSObject {
  private let panel: NSSavePanel
  private let types: [UTType]

  init(panel: NSSavePanel, types: [UTType]) {
    self.panel = panel
    self.types = types
  }

  @objc func formatChanged(_ sender: NSPopUpButton) {
    panel.allowedContentTypes = [types[sender.indexOfSelectedItem]]
  }
}
