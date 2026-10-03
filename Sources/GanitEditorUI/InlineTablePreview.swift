import AppKit
import GanitEngine

/// A bounded read-only view of one source block.
@MainActor
final class InlineTablePreview: NSView {
  let tableID: TableID
  let title = NSTextField(labelWithString: "")
  let open = NSButton(title: "Open Table", target: nil, action: nil)
  let scroll = NSScrollView()
  let cells = FlippedTableContent()
  let totals = NSTextField(labelWithString: "")
  let inspection = NSTextField(labelWithString: "Select a cell to inspect its input or formula.")
  var onOpen: ((TableCellPosition?) -> Void)?
  private var positions: [Int: TableCellPosition] = [:]
  private var details: [Int: String] = [:]
  private(set) var selectedCell: TableCellPosition?
  private var rowHeight: CGFloat = 24
  var reservedHeight: CGFloat = 220
  override var isFlipped: Bool { true }
  init(id: TableID) {
    tableID = id
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
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
    setAccessibilityElement(false)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc private func openTable() { onOpen?(selectedCell) }
  @objc private func inspectCell(_ button: NSButton) {
    selectedCell = positions[button.tag]
    inspection.stringValue = details[button.tag] ?? ""
    inspection.toolTip = inspection.stringValue
  }
  func update(_ projection: TableEditingSnapshot, result: TableResultSnapshot?, editor: SheetEditorViewController, scale: CGFloat) {
    rowHeight = 24 * scale
    reservedHeight = 114 + CGFloat(min(5, projection.rows.count) + 1) * rowHeight
    title.stringValue = projection.name + " · " + String(projection.rows.count) + " rows"
    title.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
    open.setAccessibilityLabel("Open " + projection.name + " table")
    for label in [totals, inspection] { label.font = .systemFont(ofSize: 12 * scale) }
    cells.subviews.forEach { $0.removeFromSuperview() }
    positions = [:]
    details = [:]
    let columnWidth = 140 * scale
    let columns = Array(projection.columns.prefix(8))
    let width = CGFloat(columns.count) * columnWidth
    cells.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(min(5, projection.rows.count) + 1) * rowHeight)
    for (column, item) in columns.enumerated() {
      let label = NSTextField(labelWithString: item.header)
      label.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
      label.frame = NSRect(x: CGFloat(column) * columnWidth + 6, y: 0, width: columnWidth - 12, height: rowHeight)
      cells.addSubview(label)
      for row in 0..<min(5, projection.rows.count) {
        let position = TableCellPosition(row: row, column: column)
        let address = TableSourceDocument.letters(column) + String(row + 2)
        let input = result?.interpretation(row: projection.rows[row], column: item.id).first(where: { $0.0 == "Source" })?.1 ?? projection.source(at: position)
        let value = result?.value(row: projection.rows[row], column: item.id)
        let display: String
        switch value {
        case .value(let scalar): display = editor.formatTableValue(scalar)?.display ?? ""
        case .text(let text): display = text
        case .blank: display = ""
        case .failure: display = "Error"
        case nil: display = "Pending…"
        }
        let problem = result?.cellError(row: projection.rows[row], column: item.id).map(editor.formatTableError) ?? ""
        let detail = address + " · " + item.header + ": " + input + (problem.isEmpty ? "" : " · " + problem)
        let button = NSButton(title: display, target: self, action: #selector(inspectCell(_:)))
        button.isBordered = false
        button.alignment = item.input == .value ? .right : .left
        button.font = .systemFont(ofSize: 14 * scale)
        button.tag = row * 8 + column
        button.toolTip = detail
        button.setAccessibilityLabel(address + " " + item.header + " " + display)
        button.setAccessibilityHelp(detail)
        button.frame = NSRect(x: CGFloat(column) * columnWidth + 6, y: CGFloat(row + 1) * rowHeight, width: columnWidth - 12, height: rowHeight)
        cells.addSubview(button)
        positions[button.tag] = position
        details[button.tag] = detail
      }
    }
    var footer: [String] = []
    for (index, column) in projection.columns.enumerated() {
      guard let total = column.total else { continue }
      let value = result?.aggregate(total, rectangle: .init(rows: 0..<projection.rows.count, columns: index..<(index + 1)))
      footer.append(column.header + " " + total.rawValue + ": " + (value.flatMap { editor.formatTableValue($0)?.display } ?? (result == nil ? "Pending…" : "Error")))
    }
    totals.stringValue = footer.joined(separator: "   |   ")
    totals.toolTip = totals.stringValue
    if let error = result?.calculationFailure {
      inspection.stringValue = editor.formatTableError(error)
    } else if let selectedCell, let tag = positions.first(where: { $0.value == selectedCell })?.key {
      inspection.stringValue = details[tag] ?? ""
    } else {
      selectedCell = nil
      inspection.stringValue = projection.rows.count > 5 || projection.columns.count > 8
        ? "Preview: first 5 rows and 8 columns. Open Table to see all cells."
        : "Select a cell to inspect its input or formula."
    }
    needsLayout = true
  }
  override func layout() {
    super.layout()
    let buttonWidth = min(110, bounds.width / 2)
    open.frame = NSRect(x: bounds.width - buttonWidth - 8, y: 6, width: buttonWidth, height: 28)
    title.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - buttonWidth - 24), height: 24)
    scroll.frame = NSRect(x: 4, y: 40, width: max(0, bounds.width - 8), height: max(0, bounds.height - 114))
    totals.frame = NSRect(x: 10, y: bounds.height - 68, width: max(0, bounds.width - 20), height: 24)
    inspection.frame = NSRect(x: 10, y: bounds.height - 42, width: max(0, bounds.width - 20), height: 36)
  }
}

@MainActor
final class FlippedTableContent: NSView {
  override var isFlipped: Bool { true }
}

extension SheetEditorViewController {
  /// Layout attributes do not change source bytes or calculation offsets.
  package func refreshInlineTables() {
    guard permitsInlineTables, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
    let document = TableSourceDocument(sheet)
    let ids = Set(document.editingTableIDs)
    for id in inlineTableViews.keys where !ids.contains(id) {
      inlineTableViews.removeValue(forKey: id)?.removeFromSuperview()
    }
    inlineTableRanges = [:]
    storage.beginEditing()
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
      let result = tableEvaluationSource?.utf8.elementsEqual(sheet.text.utf8) == true
        ? latestEvaluation?.tableResult(id) : nil
      preview.update(projection, result: result, editor: self, scale: scale)
      let height = preview.reservedHeight
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = 0.1
      paragraph.maximumLineHeight = 0.1
      storage.addAttributes([
        .font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear,
        .paragraphStyle: paragraph,
      ], range: range)
      let last = (storage.string as NSString).lineRange(for: NSRange(location: range.upperBound - 1, length: 0))
      let reserved = paragraph.mutableCopy() as! NSMutableParagraphStyle
      reserved.paragraphSpacing = height
      storage.addAttribute(.paragraphStyle, value: reserved, range: last)
    }
    storage.endEditing()
    (textView as? SheetTextView)?.needsLayout = true
  }
  package func layoutInlineTables() {
    guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return }
    for (id, range) in inlineTableRanges {
      guard let preview = inlineTableViews[id],
        let location = content.location(content.documentRange.location, offsetBy: range.location),
        let fragment = manager.textLayoutFragment(for: location) else { continue }
      preview.frame = NSRect(
        x: textView.textContainerOrigin.x, y: fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y,
        width: max(0, textView.bounds.width - textView.textContainerOrigin.x - textView.textContainerInset.width),
        height: preview.reservedHeight)
      preview.needsLayout = true
    }
  }
}
