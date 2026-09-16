import AppKit
import GanitDocuments
import GanitEditorUI

/// The workspace sidebar: collections and folders above the sheets of the
/// selected collection, narrowed by the search text.
@MainActor
final class SidebarViewController: NSViewController {
  /// Called when the user selects a sheet in the list.
  var didSelectSheet: (UUID) -> Void = { _ in }

  private(set) var collection: SheetCollection = .all
  private(set) var folders: [SheetFolder] = []
  private(set) var sheets: [SheetSummary] = []
  var search = "" {
    didSet { reloadSheets() }
  }

  let collectionsView = NSOutlineView()
  let sheetsView = NSTableView()
  private let library: SheetLibrary
  private let now: () -> Date
  private var items: [SidebarItem] = []
  private var collectionsHeight: NSLayoutConstraint!
  private var isSelectingProgrammatically = false

  init(library: SheetLibrary, now: @escaping () -> Date = Date.init) {
    self.library = library
    self.now = now
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func loadView() {
    collectionsView.headerView = nil
    collectionsView.style = .sourceList
    collectionsView.floatsGroupRows = false
    collectionsView.addTableColumn(NSTableColumn(identifier: .init("collection")))
    collectionsView.dataSource = self
    collectionsView.delegate = self
    collectionsView.menu = contextMenu()
    collectionsView.setAccessibilityLabel(localized("sidebar.collections", "Collections"))

    sheetsView.headerView = nil
    sheetsView.style = .sourceList
    sheetsView.rowHeight = 38
    sheetsView.addTableColumn(NSTableColumn(identifier: .init("sheet")))
    sheetsView.dataSource = self
    sheetsView.delegate = self
    sheetsView.menu = contextMenu()
    sheetsView.setAccessibilityLabel(localized("sidebar.sheets", "Sheets"))

    let collectionsScroll = scrollView(for: collectionsView)
    let sheetsScroll = scrollView(for: sheetsView)
    let separator = NSBox()
    separator.boxType = .separator
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 600))
    for view in [collectionsScroll, separator, sheetsScroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(view)
    }
    collectionsHeight = collectionsScroll.heightAnchor.constraint(equalToConstant: 200)
    collectionsHeight.priority = .defaultHigh
    NSLayoutConstraint.activate(
      [collectionsScroll, separator, sheetsScroll].flatMap {
        [
          $0.leadingAnchor.constraint(equalTo: container.leadingAnchor),
          $0.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
      } + [
        collectionsScroll.topAnchor.constraint(equalTo: container.topAnchor),
        collectionsHeight,
        collectionsScroll.heightAnchor.constraint(
          lessThanOrEqualTo: container.heightAnchor,
          multiplier: 0.6
        ),
        separator.topAnchor.constraint(equalTo: collectionsScroll.bottomAnchor),
        sheetsScroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
        sheetsScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ]
    )
    view = container
    reload()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    fitCollections()
  }

  /// Sizes the collections pane to its rows below the title bar; it is at
  /// most 60% of the sidebar and scrolls beyond that.
  private func fitCollections() {
    guard let scroll = collectionsView.enclosingScrollView, collectionsView.numberOfRows > 0 else {
      return
    }
    let height =
      collectionsView.rect(ofRow: collectionsView.numberOfRows - 1).maxY
      + scroll.safeAreaInsets.top + 8
    if abs(collectionsHeight.constant - height) > 1 {
      collectionsHeight.constant = height
    }
  }

  private func scrollView(for table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    return scroll
  }

  /// Reloads folders and sheets from the library, keeping selections.
  func reload() {
    folders = (try? library.folders()) ?? []
    let library = SidebarItem(
      localized("sidebar.library", "Library"),
      children: [
        SidebarItem(localized("sidebar.all", "All Sheets"), VisualStyle.Symbol.allSheets, .all),
        SidebarItem(localized("sidebar.recent", "Recent"), VisualStyle.Symbol.recent, .recent),
        SidebarItem(
          localized("sidebar.favorites", "Favorites"), VisualStyle.Symbol.favorites, .favorites),
        SidebarItem(localized("sidebar.archive", "Archive"), VisualStyle.Symbol.archive, .archive),
        SidebarItem(localized("sidebar.trash", "Trash"), VisualStyle.Symbol.trash, .trash),
      ])
    let folderItems = SidebarItem(
      localized("sidebar.folders", "Folders"),
      children: folders.map { SidebarItem($0.name, VisualStyle.Symbol.folder, .folder($0.id)) }
    )
    // A "Folders" heading with nothing under it sits directly above the list
    // of sheets, and reads as though the sheets were the folders.
    items = folders.isEmpty ? [library] : [library, folderItems]
    collectionsView.reloadData()
    for item in items {
      collectionsView.expandItem(item)
    }
    fitCollections()
    if !folders.contains(where: { .folder($0.id) == collection }), case .folder = collection {
      collection = .all
    }
    selectCollectionRow()
    reloadSheets()
  }

  func show(_ collection: SheetCollection) {
    self.collection = collection
    selectCollectionRow()
    reloadSheets()
  }

  /// Selects a sheet's row, if it is listed, without opening it again.
  func select(sheet id: UUID?) {
    let row = sheets.firstIndex { $0.id == id }
    isSelectingProgrammatically = true
    sheetsView.selectRowIndexes(
      row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
    isSelectingProgrammatically = false
    row.map(sheetsView.scrollRowToVisible)
  }

  /// The sheet a command applies to: the clicked row during a context menu,
  /// or else the selected row.
  var targetSheet: SheetSummary? {
    let row = sheetsView.clickedRow >= 0 ? sheetsView.clickedRow : sheetsView.selectedRow
    return sheets.indices.contains(row) ? sheets[row] : nil
  }

  /// The folder a folder command applies to.
  var targetFolder: SheetFolder? {
    let row =
      collectionsView.clickedRow >= 0 ? collectionsView.clickedRow : collectionsView.selectedRow
    guard case .folder(let id) = (collectionsView.item(atRow: row) as? SidebarItem)?.collection
    else {
      return nil
    }
    return folders.first { $0.id == id }
  }

  private func reloadSheets() {
    let selected = targetSheet?.id
    sheets = (try? library.sheets(in: collection, matching: search, now: now())) ?? []
    sheetsView.reloadData()
    select(sheet: selected)
  }

  private func selectCollectionRow() {
    let row = (0..<collectionsView.numberOfRows).first {
      (collectionsView.item(atRow: $0) as? SidebarItem)?.collection == collection
    }
    collectionsView.selectRowIndexes(
      row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
  }

  /// A menu whose items are chosen for the clicked row when it opens.
  private func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    return menu
  }
}

extension SidebarViewController: NSMenuDelegate {
  /// Move to Folder choices for a sheet, with its current folder checked.
  func folderItems(for sheet: SheetSummary) -> [NSMenuItem] {
    let none = NSMenuItem(
      title: localized("menu.noFolder", "No Folder"),
      action: #selector(WorkspaceCommands.moveSheetToFolder(_:)), keyEquivalent: "")
    none.state = sheet.folderID == nil ? .on : .off
    return [none]
      + folders.map { folder in
        let item = NSMenuItem(
          title: folder.name, action: #selector(WorkspaceCommands.moveSheetToFolder(_:)),
          keyEquivalent: "")
        item.representedObject = folder.id
        item.state = sheet.folderID == folder.id ? .on : .off
        return item
      }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    func add(_ title: String, _ action: Selector, _ represented: Any? = nil) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.representedObject = represented
    }
    if menu === collectionsView.menu {
      guard targetFolder != nil else {
        return
      }
      add(
        localized("menu.renameFolder", "Rename Folder…"),
        #selector(WorkspaceCommands.renameFolder(_:)))
      add(
        localized("menu.deleteFolder", "Delete Folder"),
        #selector(WorkspaceCommands.deleteFolder(_:)))
      return
    }
    guard let sheet = targetSheet else {
      return
    }
    switch sheet.state {
    case .active:
      add(
        localized("menu.openInNewWindow", "Open in New Window"),
        #selector(WorkspaceCommands.openInNewWindow(_:)))
      menu.addItem(.separator())
      add(localized("menu.renameSheet", "Rename…"), #selector(WorkspaceCommands.renameSheet(_:)))
      add(
        localized("menu.duplicateSheet", "Duplicate"),
        #selector(WorkspaceCommands.duplicateSheet(_:)))
      add(
        localized("menu.markdownMode", "Markdown Mode"),
        #selector(WorkspaceCommands.toggleMarkdownMode(_:)))
      menu.items.last?.state = sheet.isMarkdown ? .on : .off
      add(
        sheet.isFavorite
          ? localized("menu.removeFavorite", "Remove from Favorites")
          : localized("menu.addFavorite", "Add to Favorites"),
        #selector(WorkspaceCommands.toggleFavorite(_:))
      )
      let move = NSMenuItem(
        title: localized("menu.moveToFolder", "Move to Folder"), action: nil, keyEquivalent: "")
      move.submenu = NSMenu()
      move.submenu!.items = folderItems(for: sheet)
      menu.addItem(move)
      menu.addItem(.separator())
      add(localized("menu.archiveSheet", "Archive"), #selector(WorkspaceCommands.archiveSheet(_:)))
      add(
        localized("menu.moveToTrash", "Move to Trash"),
        #selector(WorkspaceCommands.moveSheetToTrash(_:)))
    case .archived:
      add(
        localized("menu.unarchiveSheet", "Unarchive"), #selector(WorkspaceCommands.restoreSheet(_:))
      )
      add(
        localized("menu.moveToTrash", "Move to Trash"),
        #selector(WorkspaceCommands.moveSheetToTrash(_:)))
    case .trashed:
      add(localized("menu.putBack", "Put Back"), #selector(WorkspaceCommands.restoreSheet(_:)))
      add(
        localized("menu.deleteImmediately", "Delete Immediately…"),
        #selector(WorkspaceCommands.deleteSheetImmediately(_:)))
    }
  }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? SidebarItem)?.children.count ?? items.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    (item as? SidebarItem)?.children[index] ?? items[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? SidebarItem)?.collection == nil
  }

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    (item as? SidebarItem)?.collection == nil
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    (item as? SidebarItem)?.collection != nil
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let item = item as? SidebarItem else {
      return nil
    }
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: item.title)
    label.lineBreakMode = .byTruncatingTail
    cell.textField = label
    var views: [NSView] = [label]
    if let symbol = item.symbol {
      let image = NSImageView(
        image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
      cell.imageView = image
      views.insert(image, at: 0)
    }
    let stack = NSStackView(views: views)
    stack.spacing = VisualStyle.Spacing.related
    stack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: cell.leadingAnchor, constant: VisualStyle.Spacing.tight),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard
      let collection = (collectionsView.item(atRow: collectionsView.selectedRow) as? SidebarItem)?
        .collection,
      collection != self.collection
    else {
      return
    }
    show(collection)
  }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int {
    sheets.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let sheet = sheets[row]
    let title = NSTextField(
      labelWithString: sheet.title.isEmpty ? localized("sheet.untitled", "Untitled") : sheet.title
    )
    title.lineBreakMode = .byTruncatingTail
    var titleViews: [NSView] = [title]
    if sheet.isMarkdown {
      let mark = NSImageView(
        image: NSImage(
          systemSymbolName: VisualStyle.Symbol.markdown,
          accessibilityDescription: localized("menu.markdownMode", "Markdown Mode"))!)
      mark.contentTintColor = VisualStyle.Color.secondary
      titleViews.append(mark)
    }
    let titleRow = NSStackView(views: titleViews)
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.spacing = VisualStyle.Spacing.related
    let modified = NSTextField(
      labelWithString: sheet.modifiedAt.formatted(.relative(presentation: .named)))
    modified.textColor = VisualStyle.Color.secondary
    modified.font = VisualStyle.Typography.caption
    let stack = NSStackView(views: [titleRow, modified])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.tight
    stack.translatesAutoresizingMaskIntoConstraints = false
    let cell = NSTableCellView()
    cell.textField = title
    cell.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: cell.leadingAnchor, constant: VisualStyle.Spacing.compact),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isSelectingProgrammatically, sheets.indices.contains(sheetsView.selectedRow) else {
      return
    }
    didSelectSheet(sheets[sheetsView.selectedRow].id)
  }
}

/// A row of the collections outline: a section header or a collection.
private final class SidebarItem: NSObject {
  let title: String
  let symbol: String?
  let collection: SheetCollection?
  let children: [SidebarItem]

  init(_ title: String, _ symbol: String, _ collection: SheetCollection) {
    self.title = title
    self.symbol = symbol
    self.collection = collection
    children = []
  }

  init(_ title: String, children: [SidebarItem]) {
    self.title = title
    symbol = nil
    collection = nil
    self.children = children
  }
}

func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
