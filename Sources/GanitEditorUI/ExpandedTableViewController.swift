import AppKit
import GanitEngine
import GanitFormatting

/// Shows the visible rows of one table. All edits use the sheet coordinator.
@MainActor
package final class ExpandedTableViewController: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate, NSTextFieldDelegate
{
  package let tableID: TableID
  package unowned let editor: SheetEditorViewController
  package private(set) var projection: TableEditingSnapshot?
  package private(set) var result: TableResultSnapshot?
  let grid = TableGridView()
  let frozenGrid = TableGridView()
  let frozenScroll = NSScrollView()
  private var scrollObserver: NSObjectProtocol?
  var displayOrder: [Int] = []
  package let scroll = NSScrollView()
  package let formula = NSTextField(string: "")
  let address = NSTextField(labelWithString: "A2")
  let rowLabel = NSTextField(labelWithString: "")
  private var needsInitialColumnSizing = true
  private var addRowButton: NSButton?
  private var addColumnButton: NSButton?
  let tableTitle = NSTextField(labelWithString: "")
  let inlineInput = NSTextField(string: "")
  private var editsInline = false
  var editingInput: NSTextField { editsInline ? inlineInput : formula }
  package let totals = NSTextField(labelWithString: "")
  package let status = NSTextField(labelWithString: "")
  package let observerID = UUID()
  package var navigateFailure: ((TableCellFailureOrigin) -> Void)?
  package var returnToSheet: (() -> Void)?
  package var anchor = TableCellPosition(row: 0, column: 0)
  package private(set) var isEditingCell = false
  package var referencedCells: Set<TableCellPosition> = []
  private var pickedRange: NSRange?
  private var pickedSource: String?
  private var pickAnchor: TableCellPosition?
  private var editSource: String?
  private var selectionIDs: (RowID, ColumnID)?
  private var anchorIDs: (RowID, ColumnID)?
  private var editOrigin: (RowID, ColumnID)?
  package var position = TableCellPosition(row: 0, column: 0)

  package init(editor: SheetEditorViewController, table: TableID) {
    self.editor = editor
    tableID = table
    super.init(nibName: nil, bundle: nil)
    editor.tableProjectionObservers[observerID] = { [weak self] in self?.refresh() }
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  package override func loadView() {
    view = NSView()
    let back = NSButton(
      title: localized("table.return", "Return to Sheet"), target: self, action: #selector(goBack))
    formula.setAccessibilityLabel(localized("table.formula", "Cell input or formula"))
    status.setAccessibilityLabel(localized("table.status", "Table status"))
    let complete = NSButton(
      title: localized("table.complete", "Complete"), target: self,
      action: #selector(showCompletions))
    let reference = NSButton(
      title: localized("table.insertReference", "Reference…"), target: self,
      action: #selector(insertReferenceWithKeyboard))
    let actions = NSButton(
      title: localized("table.actions", "Add / Actions"), target: self,
      action: #selector(showActions))
    let addRow = NSButton(title: "+ Row", target: self, action: #selector(addRow))
    let addColumn = NSButton(title: "+ Column", target: self, action: #selector(addColumn))
    addRowButton = addRow
    addColumnButton = addColumn
    tableTitle.lineBreakMode = .byTruncatingTail
    tableTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tableTitle.font = .systemFont(ofSize: 15, weight: .semibold)
    let top = NSStackView(views: [back, tableTitle, addRow, addColumn, actions])
    rowLabel.setAccessibilityLabel("Selected row label")
    rowLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rowLabel.lineBreakMode = .byTruncatingTail
    status.maximumNumberOfLines = 5
    status.lineBreakMode = .byWordWrapping
    let inputRow = NSStackView(views: [address, rowLabel, reference, complete])
    formula.cell?.wraps = true
    formula.cell?.isScrollable = false
    formula.maximumNumberOfLines = 3
    inputRow.orientation = .horizontal
    inputRow.spacing = VisualStyle.Spacing.standard
    top.orientation = .horizontal
    top.spacing = VisualStyle.Spacing.standard
    formula.delegate = self
    inlineInput.delegate = self
    inlineInput.font = VisualStyle.Typography.answer(scale: 1)
    inlineInput.focusRingType = .none
    address.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    address.setAccessibilityLabel("Selected cell address")
    formula.placeholderString = "Enter a value or =SUM(A2:B2)"
    formula.toolTip =
      "Formulas work in every column. Return saves; Tab moves right; Escape cancels."
    grid.headerView = TableGridHeaderView()
    (grid.headerView as? TableGridHeaderView)?.controller = self
    grid.controller = self
    grid.dataSource = self
    grid.delegate = self
    grid.rowHeight = 30
    grid.intercellSpacing = NSSize(width: 1, height: 1)
    grid.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
    grid.gridColor = VisualStyle.Color.separator
    grid.usesAlternatingRowBackgroundColors = false
    grid.columnAutoresizingStyle = .noColumnAutoresizing
    grid.selectionHighlightStyle = .none
    grid.setAccessibilityLabel(localized("table.grid", "Calculation table"))
    scroll.automaticallyAdjustsContentInsets = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = grid
    totals.setAccessibilityLabel(localized("table.totals", "Table totals"))
    totals.font = VisualStyle.Typography.answer(scale: 1)
    totals.lineBreakMode = .byTruncatingTail
    frozenGrid.controller = self
    frozenGrid.dataSource = self
    frozenGrid.delegate = self
    frozenGrid.headerView = NSTableHeaderView()
    frozenGrid.selectionHighlightStyle = .none
    frozenGrid.rowHeight = grid.rowHeight
    frozenScroll.documentView = frozenGrid
    frozenScroll.hasVerticalScroller = false
    frozenScroll.widthAnchor.constraint(equalToConstant: 170).isActive = true
    frozenScroll.isHidden = true
    scroll.contentView.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.frozenScroll.contentView.scroll(
          to: .init(x: 0, y: self.scroll.contentView.bounds.minY))
        self.frozenScroll.reflectScrolledClipView(self.frozenScroll.contentView)
      }
    }
    let gridRow = NSStackView(views: [frozenScroll, scroll])
    gridRow.orientation = .horizontal
    gridRow.alignment = .top
    gridRow.spacing = 0
    frozenScroll.heightAnchor.constraint(equalTo: scroll.heightAnchor).isActive = true
    let stack = NSStackView(views: [top, inputRow, formula, gridRow, totals, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.standard
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
      top.widthAnchor.constraint(equalTo: stack.widthAnchor),
      inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      gridRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      totals.widthAnchor.constraint(equalTo: stack.widthAnchor),
      status.widthAnchor.constraint(equalTo: stack.widthAnchor),
      formula.widthAnchor.constraint(equalTo: stack.widthAnchor),
      formula.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
    ])
    refresh()
  }
  package override func viewDidLayout() {
    super.viewDidLayout()
    if needsInitialColumnSizing, scroll.contentSize.width > 100,
      let count = projection?.columns.count, count > 0
    {
      needsInitialColumnSizing = false
      let width = max(
        80, min(180, (scroll.contentSize.width - 46 - CGFloat(count + 1)) / CGFloat(count)))
      for column in grid.tableColumns.dropFirst() { column.width = width }
      fitNumericColumns()
      scroll.contentView.scroll(to: .init(x: 0, y: scroll.contentView.bounds.minY))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    addRowButton?.isHidden = view.bounds.width < 520
    addColumnButton?.isHidden = view.bounds.width < 520
  }
  func stopReviewObservers() {
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    scrollObserver = nil
  }
  @objc private func goBack() {
    guard commitCellEditing() else { return }
    returnToSheet?()
  }
  package var rectangle: TableCellRectangle {
    .init(
      rows: min(anchor.row, position.row)..<(max(anchor.row, position.row) + 1),
      columns: min(anchor.column, position.column)..<(max(anchor.column, position.column) + 1))
  }
  package func select(_ target: TableCellPosition, extending: Bool = false) {
    guard let projection, projection.rows.indices.contains(target.row),
      projection.columns.indices.contains(target.column), !isEditingCell
    else { return }
    position = target
    selectionIDs = (projection.rows[target.row], projection.columns[target.column].id)
    if !extending {
      anchor = target
      anchorIDs = selectionIDs
    }
    guard let visible = visibleRow(target.row) else {
      updateSummary()
      return
    }
    grid.deselectAll(nil)
    grid.scrollRowToVisible(visible)
    grid.scrollToVisible(grid.frameOfCell(atColumn: target.column + 1, row: visible))
    if target.column == 0 {
      scroll.contentView.scroll(to: .init(x: 0, y: scroll.contentView.bounds.minY))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    formula.stringValue = effectiveSource(at: target)
    grid.reloadData()
    grid.deselectAll(nil)
    updateSummary()
  }
  package func effectiveSource(at target: TableCellPosition) -> String {
    guard let projection, projection.rows.indices.contains(target.row),
      projection.columns.indices.contains(target.column)
    else { return "" }
    let raw = projection.source(at: target)
    guard projection.columns[target.column].rule != nil, !projection.isOverride(at: target) else {
      return raw
    }
    return
      (try? TableSourceDocument(editor.sheet).plainText(
        table: tableID,
        rectangle: .init(
          rows: target.row..<(target.row + 1), columns: target.column..<(target.column + 1))))
      ?? raw
  }
  package func beginEditing(inline: Bool = false) {
    guard let projection, projection.rows.indices.contains(position.row),
      projection.columns.indices.contains(position.column)
    else { return }
    editsInline = inline
    isEditingCell = true
    editOrigin = (projection.rows[position.row], projection.columns[position.column].id)
    editSource = projection.source(at: position)
    formula.stringValue = effectiveSource(at: position)
    if inline {
      inlineInput.stringValue = formula.stringValue
      inlineInput.setAccessibilityLabel("Edit " + address.stringValue)
      inlineInput.frame = grid.frameOfCell(
        atColumn: position.column + 1, row: visibleRow(position.row) ?? position.row
      )
      .insetBy(dx: 1, dy: 1)
      grid.addSubview(inlineInput, positioned: .above, relativeTo: nil)
    }
    view.window?.makeFirstResponder(editingInput)
    editingInput.selectText(nil)
    if let range = result?.problemRange(
      row: projection.rows[position.row], column: projection.columns[position.column].id),
      let field = editingInput.currentEditor() as? NSTextView,
      range.upperBound <= field.string.utf16.count
    {
      field.setSelectedRange(range)
    }
    pickedRange = nil
    referencedCells = projection.referencedCells(in: formula.stringValue, row: position.row)
  }
  package func controlTextDidBeginEditing(_ obj: Notification) {
    if obj.object as? NSTextField === formula, editsInline {
      editsInline = false
      inlineInput.removeFromSuperview()
    }
    if #available(macOS 15.0, *), let field = editingInput.currentEditor() as? NSTextView {
      field.writingToolsBehavior = .none
    }
    if !isEditingCell, let projection, projection.rows.indices.contains(position.row),
      projection.columns.indices.contains(position.column)
    {
      editsInline = false
      isEditingCell = true
      editOrigin = (projection.rows[position.row], projection.columns[position.column].id)
      editSource = projection.source(at: position)
    }
  }
  package func controlTextDidChange(_ obj: Notification) {
    if let field = obj.object as? NSTextField {
      formula.stringValue = field.stringValue
      if editsInline { inlineInput.stringValue = field.stringValue }
    }
    if formula.stringValue != pickedSource { pickedRange = nil }
    referencedCells = projection?.referencedCells(in: formula.stringValue, row: position.row) ?? []
    grid.reloadData()
  }
  package func pickReference(_ target: TableCellPosition, dragging: Bool = false) {
    guard isEditingCell, formula.stringValue.hasPrefix("="),
      let input = editingInput.currentEditor() as? NSTextView, !input.hasMarkedText()
    else { return }
    if !dragging {
      pickAnchor = target
      pickedRange = input.selectedRange()
    }
    guard let start = pickAnchor, let range = pickedRange else { return }
    func address(_ cell: TableCellPosition) -> String {
      TableSourceDocument.letters(cell.column) + String(cell.row + 2)
    }
    let reference = start == target ? address(target) : address(start) + ":" + address(target)
    input.insertText(reference, replacementRange: range)
    pickedRange = NSRange(location: range.location, length: reference.utf16.count)
    formula.stringValue = input.string
    pickedSource = input.string
    referencedCells = projection?.referencedCells(in: input.string, row: position.row) ?? []
    grid.reloadData()
  }
  @objc private func insertReferenceWithKeyboard() {
    if !isEditingCell { beginEditing() }
    guard let input = editingInput.currentEditor() as? NSTextView, !input.hasMarkedText() else {
      return
    }
    let range = input.selectedRange()
    prompt(localized("table.referenceAddress", "Cell reference, for example A2")) {
      [weak self] text in
      guard let self else { return }
      view.window?.makeFirstResponder(editingInput)
      guard let field = editingInput.currentEditor() as? NSTextView else { return }
      field.setSelectedRange(range)
      if !field.string.hasPrefix("=") {
        field.insertText("=", replacementRange: .init(location: 0, length: 0))
      }
      field.insertText(text)
      formula.stringValue = field.string
      referencedCells = projection?.referencedCells(in: field.string, row: position.row) ?? []
      grid.reloadData()
    }
  }
  @objc private func showCompletions() {
    if !isEditingCell { beginEditing() }
    let menu = NSMenu()
    let headers =
      projection?.columns.map {
        "[@["
          + $0.header.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "]", with: "\\]") + "]]"
      } ?? []
    let definitions = result?.noteDefinitions.map { $0.0 } ?? []
    for text in [
      "sum(", "average(", "median(", "min(", "max(", "count(", "round(", "sqrt(", "abs(",
    ] + headers + definitions {
      let item = NSMenuItem(title: text, action: #selector(insertCompletion(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = text
      if let definition = result?.noteDefinitions.first(where: { $0.0 == text }) {
        item.title =
          text + " = " + (editor.formatTableValue(definition.1)?.display ?? "") + " · Note"
        item.toolTip = "Note definition"
      } else if text.hasPrefix("[@") {
        item.title = text + " · Current row"
      }
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: formula.bounds.maxY), in: formula)
  }
  @objc func insertCompletion(_ sender: NSMenuItem) {
    guard let input = editingInput.currentEditor() as? NSTextView, !input.hasMarkedText() else {
      return
    }
    if input.string.isEmpty { input.insertText("=") }
    input.insertText(sender.representedObject as? String ?? sender.title)
    formula.stringValue = input.string
  }
  package func controlTextDidEndEditing(_ obj: Notification) {
    // Losing focus does not discard the draft or commit marked input.
  }
  package func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
    -> Bool
  {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      cancelEditing()
      return true
    }
    let enter = selector == #selector(NSResponder.insertNewline(_:))
    let tab = selector == #selector(NSResponder.insertTab(_:))
    let backTab = selector == #selector(NSResponder.insertBacktab(_:))
    if enter || tab || backTab {
      guard !textView.hasMarkedText(), commitCellEditing() else { return true }
      moveAfterCommit(
        horizontal: !enter,
        backwards: backTab || (enter && NSApp.currentEvent?.modifierFlags.contains(.shift) == true))
      return true
    }
    return false
  }
  @discardableResult
  package func commitCellEditing() -> Bool {
    guard isEditingCell else { return true }
    guard (editingInput.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
      return false
    }
    guard let projection, let editOrigin,
      projection.rows.indices.contains(position.row),
      projection.columns.indices.contains(position.column),
      projection.rows[position.row] == editOrigin.0,
      projection.columns[position.column].id == editOrigin.1,
      projection.source(at: position).utf8.elementsEqual((editSource ?? "").utf8)
    else {
      status.stringValue = localized("table.stale", "The cell changed. Cancel and select it again.")
      return false
    }
    let source = normalizedCellInput(formula.stringValue)
    if source == effectiveSource(at: position) {
      isEditingCell = false
      inlineInput.removeFromSuperview()
      editsInline = false
      referencedCells = []
      view.window?.makeFirstResponder(grid)
      refresh()
      return true
    }
    let before = position
    isEditingCell = false
    editor.documentUndoManager.beginUndoGrouping()
    defer { editor.documentUndoManager.endUndoGrouping() }
    do {
      try editor.setTableCell(tableID, at: position, source: source)
      editor.documentUndoManager.registerUndo(withTarget: self) { controller in
        controller.restoreSelection(before)
      }
      inlineInput.removeFromSuperview()
      editsInline = false
      referencedCells = []
      view.window?.makeFirstResponder(grid)
      refresh()
      return true
    } catch {
      isEditingCell = true
      status.stringValue = String(describing: error)
      return false
    }
  }
  private func restoreSelection(_ target: TableCellPosition) {
    let previous = position
    refresh()
    select(target)
    editor.documentUndoManager.registerUndo(withTarget: self) { $0.restoreSelection(previous) }
  }
  package func cancelEditing() {
    isEditingCell = false
    editOrigin = nil
    editingInput.abortEditing()
    inlineInput.removeFromSuperview()
    editsInline = false
    referencedCells = []
    formula.stringValue = effectiveSource(at: position)
    view.window?.makeFirstResponder(grid)
    grid.reloadData()
    updateSummary()
  }

  package func refresh() {
    let next = TableEditingSnapshot(TableSourceDocument(editor.sheet), id: tableID)
    let columnsChanged = projection?.columns.map(\.id) != next?.columns.map(\.id)
    projection = next
    if let next, !next.rows.isEmpty, !next.columns.isEmpty {
      func mapped(_ ids: (RowID, ColumnID)?, fallback: TableCellPosition) -> TableCellPosition {
        .init(
          row: ids.flatMap { next.rows.firstIndex(of: $0.0) }
            ?? min(fallback.row, next.rows.count - 1),
          column: ids.flatMap { pair in next.columns.firstIndex { $0.id == pair.1 } }
            ?? min(fallback.column, next.columns.count - 1))
      }
      position = mapped(selectionIDs, fallback: position)
      anchor = mapped(anchorIDs, fallback: anchor)
    }
    result =
      editor.tableEvaluationSource?.utf8.elementsEqual(editor.sheet.text.utf8) == true
      ? editor.latestEvaluation?.tableResult(tableID) : nil
    displayOrder = result?.reviewRows() ?? Array(next?.rows.indices ?? 0..<0)
    if let first = displayOrder.first, !displayOrder.contains(position.row) {
      position.row = first
      anchor = position
      selectionIDs = next.map { ($0.rows[first], $0.columns[position.column].id) }
      anchorIDs = selectionIDs
    }
    if columnsChanged {
      let widths = Dictionary(
        uniqueKeysWithValues: grid.tableColumns.map { ($0.identifier, $0.width) })
      let defaultWidth = grid.tableColumns.dropFirst().first?.width ?? 160
      for column in grid.tableColumns { grid.removeTableColumn(column) }
      let address = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
      address.title = "#"
      address.width = 44
      address.minWidth = 44
      address.maxWidth = 44
      grid.addTableColumn(address)
      for (index, column) in next?.columns.enumerated() ?? [].enumerated() {
        let item = NSTableColumn(
          identifier: NSUserInterfaceItemIdentifier(column.id.uuid.uuidString))
        item.title = TableSourceDocument.letters(index) + "  " + column.header
        item.width = widths[item.identifier] ?? defaultWidth
        item.minWidth = 80
        grid.addTableColumn(item)
      }
    }
    for (index, column) in next?.columns.enumerated() ?? [].enumerated()
    where grid.tableColumns.indices.contains(index + 1) {
      grid.tableColumns[index + 1].title = TableSourceDocument.letters(index) + "  " + column.header
      grid.tableColumns[index + 1].headerToolTip =
        column.header + " · " + column.input.rawValue + " · Formulas start with ="
    }
    tableTitle.stringValue =
      next.map { "\($0.name) · \($0.rows.count) × \($0.columns.count)" } ?? "Table"
    grid.reloadData()
    grid.deselectAll(nil)
    refreshFrozenColumn()
    fitNumericColumns()
    if !isEditingCell, let next, next.rows.indices.contains(position.row),
      next.columns.indices.contains(position.column)
    {
      formula.stringValue = effectiveSource(at: position)
      referencedCells = []
    }
    updateSummary()
    if result == nil { status.stringValue += "   " + localized("table.pending", "Pending…") }
    if next?.rows.isEmpty == true {
      status.stringValue = "This table has no rows. Use + Row to start."
    }
    if next == nil {
      status.stringValue = localized(
        "table.unavailable", "Table is unavailable. Return to the sheet to repair its source.")
    }
  }
  package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rowView = TableGridRowView()
    rowView.backgroundColor =
      row.isMultiple(of: 2) ? .textBackgroundColor : .alternatingContentBackgroundColors[1]
    return rowView
  }
  package func numberOfRows(in tableView: NSTableView) -> Int {
    displayedRows.count + (hasTotalRow ? 1 : 0)
  }
  package func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    if row == displayedRows.count {
      return max(
        40,
        projection?.columns.indices.map { index in
          let width =
            grid.tableColumns.indices.contains(index + 1)
            ? grid.tableColumns[index + 1].width - 16 : 140
          return (totalDisplay(column: index) as NSString).boundingRect(
            with: .init(width: max(40, width), height: 10000), options: [.usesLineFragmentOrigin],
            attributes: [.font: VisualStyle.Typography.answer(scale: 1)]
          ).height + 14
        }.max() ?? 40)
    }
    guard let canonical = canonicalRow(row), let projection else { return 30 }
    var height: CGFloat = 30
    for index in projection.columns.indices {
      let width =
        grid.tableColumns.indices.contains(index + 1)
        ? grid.tableColumns[index + 1].width - 16 : 140
      let text = cellDisplay(row: canonical, column: index) as NSString
      let rect = text.boundingRect(
        with: .init(width: max(40, width), height: 1000), options: [.usesLineFragmentOrigin],
        attributes: [.font: VisualStyle.Typography.answer(scale: 1)])
      height = max(height, rect.height + 14)
    }
    return height
  }
  package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    guard let projection, let tableColumn else { return nil }
    let localIndex = tableView.tableColumns.firstIndex(of: tableColumn) ?? 0
    let index =
      tableView === frozenGrid && localIndex > 0 ? (frozenGrid.frozenColumn ?? 0) + 1 : localIndex
    if row == displayedRows.count, hasTotalRow {
      let cell = NSTableCellView()
      let label = NSTextField(
        wrappingLabelWithString: index == 0 ? "Σ" : totalDisplay(column: index - 1))
      label.frame = .init(
        x: 6, y: 4, width: tableColumn.width - 12,
        height: self.tableView(tableView, heightOfRow: row) - 8)
      label.alignment = .right
      label.toolTip = "Table total includes all data rows, including filtered rows."
      label.setAccessibilityLabel(
        (index > 0 ? projection.columns[index - 1].header + " total: " : "") + label.stringValue)
      cell.addSubview(label)
      return cell
    }
    guard let row = canonicalRow(row), projection.rows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("table-cell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? TableGridCellView
      ?? TableGridCellView()
    cell.identifier = identifier
    if cell.textField == nil {
      let label = NSTextField(labelWithString: "")
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = VisualStyle.Typography.answer(scale: 1)
      cell.addSubview(label)
      cell.textField = label
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }
    let label = cell.textField!
    cell.wantsLayer = true
    let selected =
      index > 0 && rectangle.rows.contains(row) && rectangle.columns.contains(index - 1)
    let referenced = index > 0 && referencedCells.contains(.init(row: row, column: index - 1))
    let active = index > 0 && row == position.row && index - 1 == position.column
    cell.layer?.borderWidth = active ? 2 : referenced ? 1 : 0
    cell.layer?.borderColor =
      (active ? NSColor.controlAccentColor : VisualStyle.Color.interpretation).cgColor
    cell.layer?.backgroundColor =
      selected
      ? VisualStyle.Color.selectionBackground.withAlphaComponent(0.2).cgColor
      : NSColor.clear.cgColor
    label.textColor = VisualStyle.Color.primary
    if index == 0 {
      label.stringValue = String(row + 2)
      label.alignment = .center
      label.textColor = .secondaryLabelColor
      cell.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    } else {
      let column = projection.columns[index - 1]
      let value = result?.value(row: projection.rows[row], column: column.id)
      label.stringValue = cellDisplay(row: row, column: index - 1)
      if projection.isOverride(at: .init(row: row, column: index - 1)) { label.stringValue += " •" }
      if case .text = value { label.alignment = .left } else { label.alignment = .right }
      label.maximumNumberOfLines = 0
      label.lineBreakMode = .byWordWrapping
      cell.setAccessibilityElement(true)
      cell.setAccessibilityRole(.cell)
      cell.setAccessibilitySelected(selected)
      cell.setAccessibilityHelp(cell.toolTip)
      let source = effectiveSource(at: .init(row: row, column: index - 1))
      cell.toolTip =
        result?.cellProblem(row: projection.rows[row], column: column.id)
        ?? result?.cellError(row: projection.rows[row], column: column.id).map(
          editor.formatTableError) ?? source
      cell.setAccessibilityHelp(cell.toolTip)
      if case .failure = value { label.textColor = VisualStyle.Color.failure }
      let accessible =
        "\(TableSourceDocument.letters(index - 1))\(row + 2), \(column.header), \(label.stringValue)"
      label.setAccessibilityLabel(accessible)
      cell.setAccessibilityLabel(accessible)
    }
    return cell
  }
  package func display(_ value: TableCellValue?) -> String {
    switch value {
    case .value(let scalar): return editor.formatTableValue(scalar)?.display ?? ""
    case .text(let text): return text
    case .blank: return ""
    case .failure: return localized("table.failure", "Error")
    case nil:
      if let error = result?.calculationFailure { return editor.formatTableError(error) }
      return localized("table.pending", "Pending…")
    }
  }
}
