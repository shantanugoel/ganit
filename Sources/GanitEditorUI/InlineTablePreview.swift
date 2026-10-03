import AppKit
import GanitEngine

/// A bounded read-only view of one source block.
@MainActor
final class InlineTablePreview: NSView {
  let tableID: TableID
  let title = NSTextField(labelWithString: "")
  let open = NSButton(title: "Open Table", target: nil, action: nil)
  let body = NSTextField(labelWithString: "")
  var onOpen: (() -> Void)?
  override var isFlipped: Bool { true }
  init(id: TableID) {
    tableID = id
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    for control in [title, open, body] { addSubview(control) }
    open.target = self
    open.action = #selector(openTable)
    body.maximumNumberOfLines = 0
    body.lineBreakMode = .byTruncatingTail
    setAccessibilityElement(false)
    body.setAccessibilityLabel("Table preview")
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc private func openTable() { onOpen?() }
  func update(_ projection: TableEditingSnapshot, scale: CGFloat) {
    title.stringValue = projection.name
    title.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
    body.font = .systemFont(ofSize: 14 * scale)
    open.setAccessibilityLabel("Open " + projection.name + " table")
    body.stringValue = ([projection.columns.map(\.header).joined(separator: "    ")]
      + projection.rows.prefix(5).enumerated().map { row, _ in
        projection.columns.indices.map { projection.source(at: .init(row: row, column: $0)) }.joined(separator: "    ")
      }).joined(separator: "\n")
  }
  override func layout() {
    super.layout()
    let buttonWidth = min(110, bounds.width / 2)
    open.frame = NSRect(x: bounds.width - buttonWidth - 8, y: 6, width: buttonWidth, height: 28)
    title.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - buttonWidth - 24), height: 24)
    body.frame = NSRect(x: 10, y: 40, width: max(0, bounds.width - 20), height: max(0, bounds.height - 48))
  }
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
        preview.onOpen = { [weak self] in self?.openTable(id) }
      }
      let scale = (textView as? SheetTextView)?.textScale ?? 1
      preview.update(projection, scale: scale)
      let height = 56 + CGFloat(min(5, projection.rows.count) + 1) * 22 * scale
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
      let scale = (textView as? SheetTextView)?.textScale ?? 1
      let projection = TableEditingSnapshot(TableSourceDocument(sheet), id: id)
      preview.frame = NSRect(
        x: textView.textContainerOrigin.x, y: fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y,
        width: max(0, textView.bounds.width - textView.textContainerOrigin.x - textView.textContainerInset.width),
        height: 56 + CGFloat(min(5, projection?.rows.count ?? 0) + 1) * 22 * scale)
      preview.needsLayout = true
    }
  }
}
