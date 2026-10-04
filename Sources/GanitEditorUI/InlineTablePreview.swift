import AppKit
import GanitEngine
import GanitFormatting

/// Shows and edits the cells in one source block.
@MainActor
final class InlineTablePreview: NSView, NSTextFieldDelegate {
  let tableID: TableID
  let title = NSTextField(labelWithString: "")
  let open = NSButton(title: "Open Table", target: nil, action: nil)
  let scroll = NSScrollView()
  let cells = FlippedTableContent()
  let totals = NSTextField(labelWithString: "")
  let inspection = NSTextField(labelWithString: "Select a cell to inspect its input or formula.")
  var onOpen: ((TableCellPosition?) -> Void)?
  private weak var editor: SheetEditorViewController?
  private var projection: TableEditingSnapshot?
  let cellInput = NSTextField(string: "")
  private var outsideClickMonitor: Any?
  private var editPosition: TableCellPosition?
  private var editSource: String?
  private var editIDs: (RowID, ColumnID)?
  private var positions: [Int: TableCellPosition] = [:]
  private var details: [Int: String] = [:]
  private(set) var selectedCell: TableCellPosition?
  private var columnCount = 0
  private var resultRows: [Int] = []
  private var rowOffsets: [CGFloat] = []
  private var rowSizes: [CGFloat] = []
  private var columnScale: CGFloat = 1
  private var rowHeight: CGFloat = 24
  var reservedHeight: CGFloat = 220
  override var isFlipped: Bool { true }
  init(id: TableID) {
    tableID = id
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.cornerRadius = 6
    cellInput.delegate = self
    for control in [title, open, scroll, totals, inspection] { addSubview(control) }
    open.target = self
    open.action = #selector(openTable)
    scroll.hasHorizontalScroller = true
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = false
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = cells
    inspection.maximumNumberOfLines = 2
    inspection.lineBreakMode = .byTruncatingTail
    inspection.setAccessibilityLabel("Cell input or formula")
    totals.lineBreakMode = .byTruncatingTail
    totals.setAccessibilityLabel("Table totals")
    for label in [title, totals, inspection] {
      label.setAccessibilityElement(true)
      label.setAccessibilityRole(.staticText)
    }
    open.setAccessibilityElement(true)
    open.setAccessibilityRole(.button)
    setAccessibilityElement(false)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
    cells.needsDisplay = true
  }
  override var acceptsFirstResponder: Bool { true }
  override var undoManager: UndoManager? { editor?.documentUndoManager }
  @objc func undo(_ sender: Any?) {
    cancelPreviewEdit()
    undoManager?.undo()
  }
  @objc func redo(_ sender: Any?) {
    cancelPreviewEdit()
    undoManager?.redo()
  }
  override func cancelOperation(_ sender: Any?) { clearSelection() }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    outsideClickMonitor = nil
    guard window != nil else { return }
    outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) {
      [weak self] event in
      guard let self, event.window === self.window, self.editor?.expandedTable == nil else {
        return event
      }
      if event.type == .keyDown {
        if event.keyCode == 6, self.selectedCell != nil,
          event.modifierFlags.intersection([.command, .control, .option]) == .command,
          self.editPosition == nil || self.cellInput.stringValue == self.editSource
        {
          if event.modifierFlags.contains(.shift) { self.redo(nil) } else { self.undo(nil) }
          self.window?.makeFirstResponder(self.editor?.textView)
          return nil
        }
        if event.keyCode == 53, self.selectedCell != nil {
          self.clearSelection()
          self.window?.makeFirstResponder(self.editor?.textView)
          return nil
        }
        return event
      }
      let point = self.convert(event.locationInWindow, from: nil)
      if !self.bounds.contains(point) { self.clearSelection() }
      return event
    }
  }
  func cancelPreviewEdit() {
    guard editPosition != nil else { return }
    editPosition = nil
    editIDs = nil
    editSource = nil
    cellInput.abortEditing()
    cellInput.removeFromSuperview()
  }
  func clearSelection() {
    cancelPreviewEdit()
    selectedCell = nil
    cells.selected = nil
    cells.needsDisplay = true
    inspection.stringValue = "Select a cell to inspect its input or formula."
    inspection.toolTip = nil
  }
  override func mouseDown(with event: NSEvent) { clearSelection() }
  @objc private func openTable() {
    cancelPreviewEdit()
    onOpen?(selectedCell)
  }
  @objc private func inspectCell(_ button: NSButton) {
    if editPosition != nil {
      if cellInput.stringValue.hasPrefix("="), let input = cellInput.currentEditor() as? NSTextView,
        !input.hasMarkedText(), let target = positions[button.tag]
      {
        input.insertText(
          TableSourceDocument.letters(target.column) + String(target.row + 2),
          replacementRange: input.selectedRange())
        return
      }
      cancelPreviewEdit()
    }
    window?.makeFirstResponder(self)
    selectedCell = positions[button.tag]
    cells.selected = selectedCell.flatMap { position in
      resultRows.firstIndex(of: position.row).map { .init(row: $0, column: position.column) }
    }
    cells.needsDisplay = true
    if NSApp.currentEvent?.clickCount == 2 { beginPreviewEdit() }
    inspection.stringValue = details[button.tag] ?? ""
    inspection.toolTip = inspection.stringValue
  }
  func update(
    _ projection: TableEditingSnapshot, result: TableResultSnapshot?,
    editor: SheetEditorViewController, scale: CGFloat
  ) {
    self.editor = editor
    self.projection = projection
    columnScale = scale
    rowHeight = 48 * scale
    reservedHeight = 146 + CGFloat(min(5, projection.rows.count) + 1) * rowHeight
    title.stringValue =
      projection.name + " · " + String(projection.rows.count) + " rows × "
      + String(projection.columns.count) + " columns"
    title.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
    title.maximumNumberOfLines = 2
    title.lineBreakMode = .byWordWrapping
    title.toolTip = title.stringValue
    open.setAccessibilityLabel("Open " + projection.name + " table")
    for label in [totals, inspection] { label.font = .systemFont(ofSize: 12 * scale) }
    for child in cells.subviews where child !== cellInput { child.removeFromSuperview() }
    positions = [:]
    details = [:]
    let columnWidth = 160 * scale
    let columns = projection.columns
    columnCount = columns.count
    let gutter = 40 * scale
    cells.gutter = gutter
    cells.rowHeight = rowHeight
    cells.columnWidth = columnWidth
    cells.columnCount = columns.count
    cells.selected = selectedCell.flatMap { position in
      resultRows.firstIndex(of: position.row).map { .init(row: $0, column: position.column) }
    }
    let width = gutter + CGFloat(columns.count) * columnWidth
    cells.frame = NSRect(
      x: 0, y: 0, width: width, height: CGFloat(projection.rows.count + 1) * rowHeight)
    let shownRows = result?.reviewRows() ?? Array(projection.rows.indices)
    resultRows = shownRows
    cells.selected = selectedCell.flatMap { position in
      resultRows.firstIndex(of: position.row).map { .init(row: $0, column: position.column) }
    }
    rowOffsets = []
    rowSizes = []
    var offset = rowHeight
    for row in shownRows {
      var height = rowHeight
      for column in columns {
        let text: String
        if case .text(let value) = result?.value(row: projection.rows[row], column: column.id) {
          text = value
        } else {
          text = ""
        }
        let rect = (text as NSString).boundingRect(
          with: .init(width: columnWidth - 16, height: 10000), options: [.usesLineFragmentOrigin],
          attributes: [.font: NSFont.systemFont(ofSize: 14 * scale)])
        height = max(height, ceil(rect.height) + 12)
      }
      rowOffsets.append(offset)
      rowSizes.append(height)
      offset += height
    }
    cells.rowEdges = [0, rowHeight] + zip(rowOffsets, rowSizes).map { $0 + $1 }
    cells.frame.size.height = offset
    reservedHeight = 146 + rowHeight + rowSizes.prefix(5).reduce(0, +)
    let hiddenRows = projection.rows.count - shownRows.count
    if hiddenRows > 0 { title.stringValue += " · Filter: \(hiddenRows) hidden rows" }
    if projection.columns.contains(where: { $0.reviewSort != nil }) {
      title.stringValue += " · Sorted"
    }
    for (visible, row) in shownRows.enumerated() {
      let number = NSTextField(labelWithString: String(row + 2))
      number.textColor = .secondaryLabelColor
      number.alignment = .center
      number.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
      number.identifier = NSUserInterfaceItemIdentifier("row-\(row)")
      number.frame = NSRect(
        x: 0, y: rowOffsets[visible] + 5, width: gutter, height: rowSizes[visible] - 6)
      cells.addSubview(number)
    }
    for (column, item) in columns.enumerated() {
      let label = NSTextField(
        labelWithString: TableSourceDocument.letters(column) + "  " + item.header)
      label.identifier = NSUserInterfaceItemIdentifier(String(column))
      label.toolTip = item.header
      label.setAccessibilityLabel(item.header)
      label.maximumNumberOfLines = 2
      label.lineBreakMode = .byWordWrapping
      label.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
      label.frame = NSRect(
        x: gutter + CGFloat(column) * columnWidth + 6, y: 0, width: columnWidth - 12,
        height: rowHeight)
      cells.addSubview(label)
      for (visible, row) in shownRows.enumerated() {
        let position = TableCellPosition(row: row, column: column)
        let address = TableSourceDocument.letters(column) + String(row + 2)
        let input =
          result?.interpretation(row: projection.rows[row], column: item.id).first(where: {
            $0.0 == "Source"
          })?.1 ?? projection.source(at: position)
        let value = result?.value(row: projection.rows[row], column: item.id)
        let display: String
        switch value {
        case .value(let scalar):
          display = editor.formatTableValue(scalar, column: item.id, result: result)?.display ?? ""
        case .text(let text): display = text
        case .blank: display = ""
        case .failure: display = "Error"
        case nil: display = "Pending…"
        }
        let problem =
          result?.cellProblem(row: projection.rows[row], column: item.id)
          ?? result?.cellError(row: projection.rows[row], column: item.id).map(
            editor.formatTableError) ?? ""
        let override = projection.isOverride(at: position)
        let ruleDetail =
          override
          ? " · Overrides column formula: " + (item.rule ?? "")
            + " · Cell input: " + input + " · Use Restore Column Formula to restore the rule."
          : ""
        let detail =
          address + " · " + item.header + ": " + input
          + (problem.isEmpty ? "" : " · " + problem) + ruleDetail
        let button = NSButton(
          title: display + (override ? " •" : ""), target: self, action: #selector(inspectCell(_:)))
        button.isBordered = false
        if case .text = value { button.alignment = .left } else { button.alignment = .right }
        if case .failure = value { button.contentTintColor = .systemRed }
        button.cell?.wraps = true
        button.cell?.lineBreakMode = .byWordWrapping
        button.font = .systemFont(ofSize: 14 * scale)
        button.tag = visible * columnCount + column
        button.toolTip = detail
        button.setAccessibilityLabel(
          address + " " + item.header + " " + display
            + (problem.isEmpty ? "" : ". " + problem)
            + (override ? ". Overrides column formula." : ""))
        button.setAccessibilityHelp(button.toolTip)
        button.frame = NSRect(
          x: gutter + CGFloat(column) * columnWidth + 6, y: rowOffsets[visible],
          width: columnWidth - 12, height: rowSizes[visible])
        cells.addSubview(button)
        positions[button.tag] = position
        details[button.tag] = detail
      }
    }
    var footer: [String] = []
    for (index, column) in projection.columns.enumerated() {
      guard let total = column.total else { continue }
      let value = result?.aggregate(
        total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
      let grouped =
        total == .sum
        ? result?.currencyTotals(column: column.id).map { groups in
          groups.map { $0.0 + ": " + (editor.formatTableValue($0.1)?.display ?? "") }.joined(
            separator: " · ")
        } : nil
      footer.append(
        column.header + " " + total.rawValue + ": "
          + (grouped ?? value.flatMap {
            editor.formatTableValue($0, column: column.id, result: result)?.display
          }
            ?? (result == nil ? "Pending…" : "Error")))
    }
    totals.stringValue = footer.joined(separator: "   |   ")
    totals.toolTip = totals.stringValue
    if let error = result?.calculationFailure {
      inspection.stringValue = editor.formatTableError(error)
    } else if let selectedCell, let tag = positions.first(where: { $0.value == selectedCell })?.key
    {
      inspection.stringValue = details[tag] ?? ""
    } else {
      selectedCell = nil
      inspection.stringValue =
        projection.rows.count > 5 || projection.columns.count > 8
        ? "Scroll to see all rows and columns. Double-click to edit. Open Table for review controls."
        : "Double-click a cell to edit. Open Table for the full grid."
    }
    needsLayout = true
  }
  func revealFindMatch(_ position: TableCellPosition) {
    guard editPosition == nil, let projection,
      let row = resultRows.firstIndex(of: position.row),
      projection.columns.indices.contains(position.column)
    else { return }
    selectedCell = position
    cells.selected = .init(row: row, column: position.column)
    let tag = row * columnCount + position.column
    inspection.stringValue = projection.name + " · " + (details[tag] ?? "")
    inspection.toolTip = inspection.stringValue
    cells.scrollToVisible(
      .init(
        x: cells.gutter + CGFloat(position.column) * cells.columnWidth,
        y: rowOffsets[row], width: cells.columnWidth, height: rowSizes[row]))
    cells.needsDisplay = true
  }
  @objc private func editPreviewCell() { beginPreviewEdit() }
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = cells.convert(event.locationInWindow, from: nil)
    let column = Int(floor((point.x - cells.gutter) / cells.columnWidth))
    let row =
      rowOffsets.indices.first(where: {
        point.y >= rowOffsets[$0] && point.y < rowOffsets[$0] + rowSizes[$0]
      }) ?? -1
    if resultRows.indices.contains(row), column >= 0, column < columnCount {
      selectedCell = .init(row: resultRows[row], column: column)
      cells.selected = selectedCell.flatMap { position in
        resultRows.firstIndex(of: position.row).map { .init(row: $0, column: position.column) }
      }
      cells.needsDisplay = true
    }
    let menu = NSMenu()
    if selectedCell != nil {
      let edit = NSMenuItem(
        title: "Edit Cell", action: #selector(editPreviewCell), keyEquivalent: "")
      edit.target = self
      menu.addItem(edit)
      if let selectedCell, projection?.isOverride(at: selectedCell) == true {
        let restore = NSMenuItem(
          title: "Restore Column Formula", action: #selector(restoreColumnFormula),
          keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
      }
    }
    let open = NSMenuItem(title: "Open Table", action: #selector(openTable), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    return menu
  }
  @objc func restoreColumnFormula() {
    guard let selectedCell, let editor else { return }
    cancelPreviewEdit()
    do {
      try editor.setTableCell(tableID, at: selectedCell, source: nil)
    } catch {
      inspection.stringValue = "Cannot restore the column formula. " + String(describing: error)
    }
  }
  func beginPreviewEdit() {
    guard let selectedCell, let projection, let editor,
      projection.rows.indices.contains(selectedCell.row),
      projection.columns.indices.contains(selectedCell.column)
    else { return }
    editPosition = selectedCell
    editSource = projection.source(at: selectedCell)
    editIDs = (projection.rows[selectedCell.row], projection.columns[selectedCell.column].id)
    cellInput.stringValue =
      (try? TableSourceDocument(editor.sheet).plainText(
        table: tableID,
        rectangle: .init(
          rows: selectedCell.row..<(selectedCell.row + 1),
          columns: selectedCell.column..<(selectedCell.column + 1)))) ?? editSource ?? ""
    cellInput.setAccessibilityLabel(
      "Edit " + TableSourceDocument.letters(selectedCell.column) + String(selectedCell.row + 2))
    cells.addSubview(cellInput, positioned: .above, relativeTo: nil)
    layout()
    window?.makeFirstResponder(cellInput)
    cellInput.selectText(nil)
  }
  @discardableResult
  func commitPreviewEdit() -> Bool {
    guard let position = editPosition, let editor else { return true }
    guard (cellInput.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
    let next = TableEditingSnapshot(TableSourceDocument(editor.sheet), id: tableID)
    guard let next, next.rows.indices.contains(position.row),
      next.columns.indices.contains(position.column),
      next.rows[position.row] == editIDs?.0, next.columns[position.column].id == editIDs?.1,
      next.source(at: position) == editSource
    else {
      inspection.stringValue = "The cell changed. Press Escape and select it again."
      return false
    }
    let source = TableCellInput.normalized(
      cellInput.stringValue, policy: next.columns[position.column].input,
      context: editor.tableEvaluationContext)
    cellInput.abortEditing()
    editPosition = nil
    cellInput.removeFromSuperview()
    do {
      try editor.setTableCell(tableID, at: position, source: source)
      return true
    } catch {
      editPosition = position
      cells.addSubview(cellInput, positioned: .above, relativeTo: nil)
      needsLayout = true
      inspection.stringValue = String(describing: error)
      return false
    }
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      clearSelection()
      window?.makeFirstResponder(self)
      return true
    }
    let enter = selector == #selector(NSResponder.insertNewline(_:))
    let tab = selector == #selector(NSResponder.insertTab(_:))
    let back = selector == #selector(NSResponder.insertBacktab(_:))
    if enter || tab || back {
      if enter {
        guard !textView.hasMarkedText(), commitPreviewEdit() else { return true }
      } else {
        cancelPreviewEdit()
      }
      guard var target = selectedCell, let projection else { return true }
      var row = resultRows.firstIndex(of: target.row) ?? 0
      if enter {
        row += 1
      } else {
        target.column += back ? -1 : 1
        if target.column >= projection.columns.count {
          target.column = 0
          row += 1
        }
        if target.column < 0 {
          target.column = projection.columns.count - 1
          row -= 1
        }
      }
      if resultRows.indices.contains(row), target.column < columnCount {
        target.row = resultRows[row]
        selectedCell = target
        beginPreviewEdit()
      } else {
        window?.makeFirstResponder(editor?.textView)
      }
      return true
    }
    return false
  }
  override func layout() {
    super.layout()
    let buttonWidth = min(110, bounds.width / 2)
    open.frame = NSRect(x: bounds.width - buttonWidth - 8, y: 6, width: buttonWidth, height: 28)
    title.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - buttonWidth - 24), height: 40)
    scroll.frame = NSRect(
      x: 4, y: 56, width: max(0, bounds.width - 8), height: max(0, bounds.height - 130))
    let columnWidth = 160 * columnScale
    let gutter = 40 * columnScale
    cells.columnWidth = columnWidth
    cells.gutter = gutter
    cells.frame.size.width = gutter + CGFloat(columnCount) * columnWidth
    cells.needsDisplay = true
    for control in cells.subviews {
      if let button = control as? NSButton {
        button.frame = NSRect(
          x: gutter + CGFloat(button.tag % max(1, columnCount)) * columnWidth + 6,
          y: rowOffsets[button.tag / max(1, columnCount)], width: columnWidth - 12,
          height: rowSizes[button.tag / max(1, columnCount)])
      } else if let label = control as? NSTextField,
        let column = Int(label.identifier?.rawValue ?? "")
      {
        label.frame = NSRect(
          x: gutter + CGFloat(column) * columnWidth + 6, y: 0, width: columnWidth - 12,
          height: rowHeight)
      }
    }
    if let position = editPosition {
      cellInput.frame = NSRect(
        x: gutter + CGFloat(position.column) * columnWidth + 1,
        y: rowOffsets[resultRows.firstIndex(of: position.row) ?? 0] + 1, width: columnWidth - 2,
        height: rowSizes[resultRows.firstIndex(of: position.row) ?? 0] - 2)
    }
    totals.frame = NSRect(
      x: 10, y: bounds.height - 68, width: max(0, bounds.width - 20), height: 24)
    inspection.frame = NSRect(
      x: 10, y: bounds.height - 42, width: max(0, bounds.width - 20), height: 36)
  }
}

@MainActor
final class FlippedTableContent: NSView {
  override var isFlipped: Bool { true }
  var gutter: CGFloat = 0
  var columnWidth: CGFloat = 140
  var rowHeight: CGFloat = 28
  var columnCount = 0
  var selected: TableCellPosition?
  var rowEdges: [CGFloat] = []
  func rowFrame(_ row: Int) -> (CGFloat, CGFloat) {
    guard rowEdges.indices.contains(row + 2) else {
      return (CGFloat(row + 1) * rowHeight, rowHeight)
    }
    return (rowEdges[row + 1], rowEdges[row + 2] - rowEdges[row + 1])
  }
  override func draw(_ dirtyRect: NSRect) {
    guard gutter > 0 else { return }
    NSColor.controlBackgroundColor.setFill()
    NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight).fill()
    NSRect(x: 0, y: 0, width: gutter, height: bounds.height).fill()
    if let selected {
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
      NSRect(
        x: gutter + CGFloat(selected.column) * columnWidth,
        y: rowFrame(selected.row).0,
        width: columnWidth, height: rowFrame(selected.row).1
      ).fill()
    }
    NSColor.separatorColor.setStroke()
    let lines = NSBezierPath()
    lines.lineWidth = 1
    for edge in rowEdges.isEmpty
      ? stride(from: CGFloat(0), through: bounds.height, by: rowHeight).map({ $0 }) : rowEdges
    {
      let y = edge + 0.5
      lines.move(to: .init(x: 0, y: y))
      lines.line(to: .init(x: bounds.width, y: y))
    }
    for column in 0...columnCount {
      let x = gutter + CGFloat(column) * columnWidth + 0.5
      lines.move(to: .init(x: x, y: 0))
      lines.line(to: .init(x: x, y: bounds.height))
    }
    lines.stroke()
    if let selected {
      NSColor.controlAccentColor.setStroke()
      let outline = NSBezierPath(
        rect: NSRect(
          x: gutter + CGFloat(selected.column) * columnWidth + 1,
          y: rowFrame(selected.row).0 + 1, width: columnWidth - 2,
          height: rowFrame(selected.row).1 - 2))
      outline.lineWidth = 2
      outline.stroke()
    }
  }
}

extension SheetEditorViewController {
  /// Layout attributes do not change source bytes or calculation offsets.
  package func refreshInlineTables() {
    guard permitsInlineTables, !textView.hasMarkedText(), let storage = textView.textStorage else {
      return
    }
    let document = TableSourceDocument(sheet)
    let ids = Set(document.editingTableIDs)
    if #available(macOS 15.0, *) {
      textView.writingToolsBehavior = ids.isEmpty ? .default : .none
    }
    for id in inlineTableViews.keys where !ids.contains(id) {
      inlineTableViews.removeValue(forKey: id)?.removeFromSuperview()
    }
    inlineTableRanges = [:]
    storage.beginEditing()
    storage.addAttributes(
      [
        .font: VisualStyle.Typography.source(scale: (textView as? SheetTextView)?.textScale ?? 1),
        .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default,
      ], range: NSRange(location: 0, length: storage.length))
    for id in document.editingTableIDs {
      guard let projection = TableEditingSnapshot(document, id: id) else { continue }
      let bytes = sheet.text.utf8
      let lower = bytes.index(bytes.startIndex, offsetBy: projection.utf8Range.lowerBound)
      let upper = bytes.index(bytes.startIndex, offsetBy: projection.utf8Range.upperBound)
      let range = NSRange(lower..<upper, in: sheet.text)
      inlineTableRanges[id] = range
      let preview = inlineTableViews[id] ?? InlineTablePreview(id: id)
      if inlineTableViews[id] == nil {
        inlineTableViews[id] = preview
        textView.addSubview(preview)
        preview.onOpen = { [weak self] position in
          self?.openTable(id)
          if let position { self?.expandedTable?.select(position) }
        }
      }
      let scale = (textView as? SheetTextView)?.textScale ?? 1
      let result =
        tableEvaluationSource?.utf8.elementsEqual(sheet.text.utf8) == true
        ? latestEvaluation?.tableResult(id) : nil
      preview.update(projection, result: result, editor: self, scale: scale)
      let height = preview.reservedHeight
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = 0.1
      paragraph.maximumLineHeight = 0.1
      storage.addAttributes(
        [
          .font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear,
          .paragraphStyle: paragraph,
        ], range: range)
      let last = (storage.string as NSString).lineRange(
        for: NSRange(location: range.upperBound - 1, length: 0))
      let reserved = paragraph.mutableCopy() as! NSMutableParagraphStyle
      reserved.paragraphSpacing = height
      storage.addAttribute(.paragraphStyle, value: reserved, range: last)
    }
    storage.endEditing()
    textView.typingAttributes = [
      .font: VisualStyle.Typography.source(scale: (textView as? SheetTextView)?.textScale ?? 1),
      .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default,
    ]
    (textView as? SheetTextView)?.needsLayout = true
  }
  package func layoutInlineTables() {
    guard let manager = textView.textLayoutManager, let content = manager.textContentManager else {
      return
    }
    for (id, range) in inlineTableRanges {
      guard let preview = inlineTableViews[id],
        let location = content.location(content.documentRange.location, offsetBy: range.location),
        let fragment = manager.textLayoutFragment(for: location)
      else { continue }
      preview.frame = NSRect(
        x: textView.textContainerOrigin.x,
        y: fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y,
        width: max(
          0,
          min(
            textView.textContainer?.size.width ?? 0,
            textView.bounds.width - textView.textContainerOrigin.x
              - textView.textContainerInset.width)
        ),
        height: preview.reservedHeight)
      preview.needsLayout = true
    }
  }
}
