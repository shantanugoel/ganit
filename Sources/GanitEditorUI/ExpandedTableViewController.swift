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
  package let scroll = NSScrollView()
  package let formula = NSTextField(string: "")
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
      title: localized("table.actions", "Table Actions"), target: self,
      action: #selector(showActions))
    let top = NSStackView(views: [back, actions])
    let inputRow = NSStackView(views: [formula, reference, complete])
    inputRow.orientation = .horizontal
    inputRow.spacing = VisualStyle.Spacing.standard
    top.orientation = .horizontal
    top.spacing = VisualStyle.Spacing.group
    formula.delegate = self
    grid.controller = self
    grid.dataSource = self
    grid.delegate = self
    grid.rowHeight = 30
    grid.intercellSpacing = NSSize(width: 1, height: 1)
    grid.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
    grid.gridColor = VisualStyle.Color.separator
    grid.usesAlternatingRowBackgroundColors = false
    grid.selectionHighlightStyle = .none
    grid.setAccessibilityLabel(localized("table.grid", "Calculation table"))
    scroll.automaticallyAdjustsContentInsets = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = grid
    totals.setAccessibilityLabel(localized("table.totals", "Table totals"))
    totals.font = VisualStyle.Typography.answer(scale: 1)
    totals.lineBreakMode = .byTruncatingTail
    let stack = NSStackView(views: [top, inputRow, scroll, totals, status])
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
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      totals.widthAnchor.constraint(equalTo: stack.widthAnchor),
      status.widthAnchor.constraint(equalTo: stack.widthAnchor),
      formula.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
    ])
    refresh()
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
    grid.selectRowIndexes(IndexSet(integer: target.row), byExtendingSelection: false)
    grid.scrollRowToVisible(target.row)
    grid.scrollToVisible(grid.frameOfCell(atColumn: target.column + 1, row: target.row))
    formula.stringValue = effectiveSource(at: target)
    grid.reloadData()
    grid.selectRowIndexes(IndexSet(integer: target.row), byExtendingSelection: false)
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
  package func beginEditing() {
    guard let projection, projection.rows.indices.contains(position.row),
      projection.columns.indices.contains(position.column)
    else { return }
    isEditingCell = true
    editOrigin = (projection.rows[position.row], projection.columns[position.column].id)
    editSource = projection.source(at: position)
    formula.stringValue = effectiveSource(at: position)
    view.window?.makeFirstResponder(formula)
    formula.selectText(nil)
    pickedRange = nil
    referencedCells = projection.referencedCells(in: formula.stringValue, row: position.row)
  }
  package func controlTextDidBeginEditing(_ obj: Notification) {
    if !isEditingCell, let projection, projection.rows.indices.contains(position.row),
      projection.columns.indices.contains(position.column)
    {
      isEditingCell = true
      editOrigin = (projection.rows[position.row], projection.columns[position.column].id)
      editSource = projection.source(at: position)
    }
  }
  package func controlTextDidChange(_ obj: Notification) {
    if formula.stringValue != pickedSource { pickedRange = nil }
    referencedCells = projection?.referencedCells(in: formula.stringValue, row: position.row) ?? []
    grid.reloadData()
  }
  package func pickReference(_ target: TableCellPosition, dragging: Bool = false) {
    guard isEditingCell, formula.stringValue.hasPrefix("="),
      let input = formula.currentEditor() as? NSTextView, !input.hasMarkedText()
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
    pickedSource = input.string
    referencedCells = projection?.referencedCells(in: input.string, row: position.row) ?? []
    grid.reloadData()
  }
  @objc private func insertReferenceWithKeyboard() {
    if !isEditingCell { beginEditing() }
    guard let input = formula.currentEditor() as? NSTextView, !input.hasMarkedText() else { return }
    let range = input.selectedRange()
    prompt(localized("table.referenceAddress", "Cell reference, for example A2")) {
      [weak self] text in
      guard let self else { return }
      view.window?.makeFirstResponder(formula)
      guard let field = formula.currentEditor() as? NSTextView else { return }
      field.setSelectedRange(range)
      if !field.string.hasPrefix("=") {
        field.insertText("=", replacementRange: .init(location: 0, length: 0))
      }
      field.insertText(text)
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
    for text in ["sum(", "average(", "median(", "min(", "max(", "count("] + headers {
      let item = NSMenuItem(title: text, action: #selector(insertCompletion(_:)), keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: formula.bounds.maxY), in: formula)
  }
  @objc private func insertCompletion(_ sender: NSMenuItem) {
    guard let input = formula.currentEditor() as? NSTextView, !input.hasMarkedText() else { return }
    if input.string.isEmpty { input.insertText("=") }
    input.insertText(sender.title)
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
    if selector == #selector(NSResponder.insertNewline(_:))
      || selector == #selector(NSResponder.insertTab(_:))
    {
      guard !textView.hasMarkedText(), commitCellEditing() else { return true }
      select(
        .init(
          row: min(position.row + 1, (projection?.rows.count ?? 1) - 1), column: position.column))
      return true
    }
    return false
  }
  @discardableResult
  package func commitCellEditing() -> Bool {
    guard isEditingCell else { return true }
    guard (formula.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
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
    let source = formula.stringValue
    let before = position
    isEditingCell = false
    editor.documentUndoManager.beginUndoGrouping()
    defer { editor.documentUndoManager.endUndoGrouping() }
    do {
      try editor.setTableCell(tableID, at: position, source: source)
      editor.documentUndoManager.registerUndo(withTarget: self) { controller in
        controller.restoreSelection(before)
      }
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
    formula.abortEditing()
    formula.stringValue =
      projection.flatMap {
        $0.columns.indices.contains(position.column) ? $0.source(at: position) : nil
      } ?? ""
    view.window?.makeFirstResponder(grid)
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
    if columnsChanged {
      for column in grid.tableColumns { grid.removeTableColumn(column) }
      let address = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
      address.title = "#"
      address.width = 44
      grid.addTableColumn(address)
      for (index, column) in next?.columns.enumerated() ?? [].enumerated() {
        let item = NSTableColumn(
          identifier: NSUserInterfaceItemIdentifier(column.id.uuid.uuidString))
        item.title = TableSourceDocument.letters(index) + "  " + column.header
        item.width = 160
        item.minWidth = 80
        grid.addTableColumn(item)
      }
    }
    grid.reloadData()
    if let next, next.rows.indices.contains(position.row) {
      grid.selectRowIndexes(IndexSet(integer: position.row), byExtendingSelection: false)
    }
    if !isEditingCell, let next, next.rows.indices.contains(position.row),
      next.columns.indices.contains(position.column)
    {
      formula.stringValue = effectiveSource(at: position)
      referencedCells = next.referencedCells(in: formula.stringValue, row: position.row)
    }
    updateSummary()
    if result == nil { status.stringValue += "   " + localized("table.pending", "Pending…") }
    if next == nil {
      status.stringValue = localized(
        "table.unavailable", "Table is unavailable. Return to the sheet to repair its source.")
    }
  }
  package func numberOfRows(in tableView: NSTableView) -> Int { projection?.rows.count ?? 0 }
  package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    guard let projection, let tableColumn, projection.rows.indices.contains(row) else { return nil }
    let index = grid.tableColumns.firstIndex(of: tableColumn) ?? 0
    let identifier = NSUserInterfaceItemIdentifier("table-cell")
    let cell =
      grid.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? NSTableCellView()
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
    cell.layer?.borderWidth = referenced ? 1 : 0
    cell.layer?.borderColor = VisualStyle.Color.interpretation.cgColor
    cell.layer?.backgroundColor =
      selected
      ? VisualStyle.Color.selectionBackground.withAlphaComponent(0.2).cgColor
      : NSColor.clear.cgColor
    label.textColor = VisualStyle.Color.primary
    if index == 0 {
      label.stringValue = String(row + 2)
      label.alignment = .left
    } else {
      let column = projection.columns[index - 1]
      let value = result?.value(row: projection.rows[row], column: column.id)
      label.stringValue = display(value)
      if projection.isOverride(at: .init(row: row, column: index - 1)) { label.stringValue += " •" }
      label.alignment = column.input == .text ? .left : .right
      if case .failure = value { label.textColor = VisualStyle.Color.failure }
      label.setAccessibilityLabel(
        "\(TableSourceDocument.letters(index - 1))\(row + 2), \(column.header), \(label.stringValue)"
      )
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
