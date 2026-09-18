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
  /// Keeps "5 minutes ago" true while a window stays open.
  private var relativeTimes: Timer?
  /// Shown in place of an empty list, so a search that finds nothing says so.
  let emptyLabel = NSTextField(labelWithString: "")

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

    emptyLabel.textColor = VisualStyle.Color.secondary
    emptyLabel.font = VisualStyle.Typography.caption
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byTruncatingTail
    emptyLabel.isHidden = true

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
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: sheetsScroll.centerXAnchor),
      emptyLabel.topAnchor.constraint(
        equalTo: sheetsScroll.topAnchor, constant: VisualStyle.Spacing.related * 2),
      emptyLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: container.leadingAnchor, constant: VisualStyle.Spacing.related),
      emptyLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -VisualStyle.Spacing.related),
    ])
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

  /// What an empty list says: why there is nothing rather than nothing at all.
  static func emptyText(searching search: String, in collection: SheetCollection) -> String {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.isEmpty else {
      return String(
        format: localized("sidebar.noMatches", "No sheets match “%@”"), query)
    }
    switch collection {
    case .trash:
      return localized("sidebar.emptyTrash", "The Trash is empty")
    case .archive:
      return localized("sidebar.emptyArchive", "Nothing is archived")
    case .favorites:
      return localized("sidebar.emptyFavorites", "No favourites yet")
    default:
      return localized("sidebar.emptySheets", "No sheets here yet")
    }
  }

  /// How long ago a sheet was last written, as the list shows it.
  static func relativeTime(of date: Date, to now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
  }

  /// Rewrites the times in the list, which go stale as the minutes pass.
  func refreshRelativeTimes() {
    guard sheetsView.numberOfRows > 0 else {
      return
    }
    let selection = sheetsView.selectedRowIndexes
    sheetsView.reloadData(
      forRowIndexes: IndexSet(integersIn: 0..<sheetsView.numberOfRows),
      columnIndexes: IndexSet(integer: 0))
    sheetsView.selectRowIndexes(selection, byExtendingSelection: false)
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard relativeTimes == nil else {
      return
    }
    // A minute is the finest step the list shows.
    let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshRelativeTimes() }
    }
    timer.tolerance = 15
    RunLoop.main.add(timer, forMode: .common)
    relativeTimes = timer
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    relativeTimes?.invalidate()
    relativeTimes = nil
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
    emptyLabel.stringValue = Self.emptyText(searching: search, in: collection)
    emptyLabel.isHidden = !sheets.isEmpty
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
      let dollar = NSMenuItem(
        title: localized("menu.dollarMeans", "Dollar Means"), action: nil, keyEquivalent: "")
      dollar.submenu = NSMenu()
      dollar.submenu!.items = MainMenu.dollarCurrencyItems()
      menu.addItem(dollar)
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
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    var titleViews: [NSView] = [title]
    if sheet.isMarkdown {
      let mark = NSImageView(
        image: NSImage(
          systemSymbolName: VisualStyle.Symbol.markdown,
          accessibilityDescription: localized("menu.markdownMode", "Markdown Mode"))!)
      mark.contentTintColor = VisualStyle.Color.secondary
      mark.setContentCompressionResistancePriority(.required, for: .horizontal)
      titleViews.append(mark)
    }
    let titleRow = NSStackView(views: titleViews)
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.distribution = .fill
    titleRow.spacing = VisualStyle.Spacing.related
    let modified = NSTextField(labelWithString: Self.relativeTime(of: sheet.modifiedAt, to: now()))
    modified.textColor = VisualStyle.Color.secondary
    modified.font = VisualStyle.Typography.caption
    modified.lineBreakMode = .byTruncatingTail
    modified.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
      stack.trailingAnchor.constraint(
        equalTo: cell.trailingAnchor, constant: -VisualStyle.Spacing.compact),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      modified.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
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
