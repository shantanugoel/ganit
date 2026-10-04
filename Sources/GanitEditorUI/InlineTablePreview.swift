import AppKit
import GanitEngine
import GanitFormatting

/// A bounded read-only view of one source block.
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
  private var editPosition: TableCellPosition?
  private var editSource: String?
  private var editIDs: (RowID, ColumnID)?
  private var positions: [Int: TableCellPosition] = [:]
  private var details: [Int: String] = [:]
  private(set) var selectedCell: TableCellPosition?
  private var columnCount = 0
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
  @objc private func openTable() { if commitPreviewEdit() { onOpen?(selectedCell) } }
  @objc private func inspectCell(_ button: NSButton) {
    if editPosition != nil {
      if cellInput.stringValue.hasPrefix("="), let input = cellInput.currentEditor() as? NSTextView,
        !input.hasMarkedText(), let target = positions[button.tag]
      {
        input.insertText(TableSourceDocument.letters(target.column) + String(target.row + 2))
        return
      }
      guard commitPreviewEdit() else { return }
    }
    selectedCell = positions[button.tag]
    cells.selected = selectedCell
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
    rowHeight = 28 * scale
    reservedHeight = 114 + CGFloat(min(5, projection.rows.count) + 1) * rowHeight
    title.stringValue =
      projection.name + " · " + String(projection.rows.count) + " rows × "
      + String(projection.columns.count) + " columns"
    title.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
    open.setAccessibilityLabel("Open " + projection.name + " table")
    for label in [totals, inspection] { label.font = .systemFont(ofSize: 12 * scale) }
    for child in cells.subviews where child !== cellInput { child.removeFromSuperview() }
    positions = [:]
    details = [:]
    let columnWidth = 140 * scale
    let columns = Array(projection.columns.prefix(8))
    columnCount = columns.count
    let gutter = 40 * scale
    cells.gutter = gutter
    cells.rowHeight = rowHeight
    cells.columnWidth = columnWidth
    cells.columnCount = columns.count
    cells.selected = selectedCell
    let width = gutter + CGFloat(columns.count) * columnWidth
    cells.frame = NSRect(
      x: 0, y: 0, width: width, height: CGFloat(min(5, projection.rows.count) + 1) * rowHeight)
    for row in 0..<min(5, projection.rows.count) {
      let number = NSTextField(labelWithString: String(row + 2))
      number.textColor = .secondaryLabelColor
      number.alignment = .center
      number.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
      number.identifier = NSUserInterfaceItemIdentifier("row-\(row)")
      number.frame = NSRect(
        x: 0, y: CGFloat(row + 1) * rowHeight + 5, width: gutter, height: rowHeight - 6)
      cells.addSubview(number)
    }
    for (column, item) in columns.enumerated() {
      let label = NSTextField(
        labelWithString: TableSourceDocument.letters(column) + "  " + item.header)
      label.identifier = NSUserInterfaceItemIdentifier(String(column))
      label.lineBreakMode = .byTruncatingTail
      label.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
      label.frame = NSRect(
        x: gutter + CGFloat(column) * columnWidth + 6, y: 0, width: columnWidth - 12,
        height: rowHeight)
      cells.addSubview(label)
      for row in 0..<min(5, projection.rows.count) {
        let position = TableCellPosition(row: row, column: column)
        let address = TableSourceDocument.letters(column) + String(row + 2)
        let input =
          result?.interpretation(row: projection.rows[row], column: item.id).first(where: {
            $0.0 == "Source"
          })?.1 ?? projection.source(at: position)
        let value = result?.value(row: projection.rows[row], column: item.id)
        let display: String
        switch value {
        case .value(let scalar): display = editor.formatTableValue(scalar)?.display ?? ""
        case .text(let text): display = text
        case .blank: display = ""
        case .failure: display = "Error"
        case nil: display = "Pending…"
        }
        let problem =
          result?.cellError(row: projection.rows[row], column: item.id).map(editor.formatTableError)
          ?? ""
        let detail =
          address + " · " + item.header + ": " + input + (problem.isEmpty ? "" : " · " + problem)
        let button = NSButton(title: display, target: self, action: #selector(inspectCell(_:)))
        button.isBordered = false
        if case .text = value { button.alignment = .left } else { button.alignment = .right }
        if case .failure = value { button.contentTintColor = .systemRed }
        button.cell?.lineBreakMode = .byTruncatingTail
        button.font = .systemFont(ofSize: 14 * scale)
        button.tag = row * 8 + column
        button.toolTip = detail
        button.setAccessibilityLabel(address + " " + item.header + " " + display)
        button.setAccessibilityHelp(detail)
        button.frame = NSRect(
          x: gutter + CGFloat(column) * columnWidth + 6, y: CGFloat(row + 1) * rowHeight,
          width: columnWidth - 12, height: rowHeight)
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
      footer.append(
        column.header + " " + total.rawValue + ": "
          + (value.flatMap { editor.formatTableValue($0)?.display }
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
        ? "Preview: first 5 rows and 8 columns. Open Table to see all cells. Double-click to edit."
        : "Double-click a cell to edit. Open Table for the full grid."
    }
    needsLayout = true
  }
  @objc private func editPreviewCell() { beginPreviewEdit() }
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = cells.convert(event.locationInWindow, from: nil)
    let column = Int(floor((point.x - cells.gutter) / cells.columnWidth))
    let row = Int(floor(point.y / rowHeight)) - 1
    if let projection, projection.rows.indices.contains(row), column >= 0, column < columnCount {
      selectedCell = .init(row: row, column: column)
      cells.selected = selectedCell
      cells.needsDisplay = true
    }
    let menu = NSMenu()
    if selectedCell != nil {
      let edit = NSMenuItem(
        title: "Edit Cell", action: #selector(editPreviewCell), keyEquivalent: "")
      edit.target = self
      menu.addItem(edit)
    }
    let open = NSMenuItem(title: "Open Table", action: #selector(openTable), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    return menu
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
    let source = TableCellInput.normalized(cellInput.stringValue)
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
      editPosition = nil
      cellInput.abortEditing()
      cellInput.removeFromSuperview()
      window?.makeFirstResponder(editor?.textView)
      return true
    }
    let enter = selector == #selector(NSResponder.insertNewline(_:))
    let tab = selector == #selector(NSResponder.insertTab(_:))
    let back = selector == #selector(NSResponder.insertBacktab(_:))
    if enter || tab || back {
      guard commitPreviewEdit(), var target = selectedCell, let projection else { return true }
      if enter {
        target.row += 1
      } else {
        target.column += back ? -1 : 1
        if target.column >= projection.columns.count {
          target.column = 0
          target.row += 1
        }
        if target.column < 0 {
          target.column = projection.columns.count - 1
          target.row -= 1
        }
      }
      if target.row >= 0, target.row < min(5, projection.rows.count), target.column < columnCount {
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
    title.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - buttonWidth - 24), height: 24)
    scroll.frame = NSRect(
      x: 4, y: 40, width: max(0, bounds.width - 8), height: max(0, bounds.height - 114))
    let columnWidth = max(
      80 * columnScale,
      (scroll.contentSize.width - 40 * columnScale) / CGFloat(max(1, columnCount)))
    let gutter = 40 * columnScale
    cells.columnWidth = columnWidth
    cells.gutter = gutter
    cells.frame.size.width = gutter + CGFloat(columnCount) * columnWidth
    cells.needsDisplay = true
    for control in cells.subviews {
      if let button = control as? NSButton {
        button.frame = NSRect(
          x: gutter + CGFloat(button.tag % 8) * columnWidth + 6,
          y: CGFloat(button.tag / 8 + 1) * rowHeight, width: columnWidth - 12, height: rowHeight)
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
        y: CGFloat(position.row + 1) * rowHeight + 1, width: columnWidth - 2, height: rowHeight - 2)
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
  override func draw(_ dirtyRect: NSRect) {
    guard gutter > 0 else { return }
    NSColor.controlBackgroundColor.setFill()
    NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight).fill()
    NSRect(x: 0, y: 0, width: gutter, height: bounds.height).fill()
    if let selected {
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
      NSRect(
        x: gutter + CGFloat(selected.column) * columnWidth,
        y: CGFloat(selected.row + 1) * rowHeight,
        width: columnWidth, height: rowHeight
      ).fill()
    }
    NSColor.separatorColor.setStroke()
    let lines = NSBezierPath()
    lines.lineWidth = 1
    for row in 0...Int(bounds.height / rowHeight) {
      let y = CGFloat(row) * rowHeight + 0.5
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
          y: CGFloat(selected.row + 1) * rowHeight + 1, width: columnWidth - 2,
          height: rowHeight - 2))
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
          textView.bounds.width - textView.textContainerOrigin.x - textView.textContainerInset.width
        ),
        height: preview.reservedHeight)
      preview.needsLayout = true
    }
  }
}
