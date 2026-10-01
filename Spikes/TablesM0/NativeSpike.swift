import AppKit
import GanitEditorUI
import GanitEngine

// Tiny AppKit harness, not production table layout. Grid edits patch canonical
// source via the existing editor and therefore use its document UndoManager.
@MainActor
final class NativeProof: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let editor: SheetEditorViewController
  let grid = NSTableView()
  let preview = PreviewTextView(frame: .zero)
  let window: NSWindow
  let initial: String
  var savedSelection = NSRange(location: 0, length: 0)
  var commits = 0

  init(source: String) throws {
    initial = source
    editor = SheetEditorViewController(text: source, context: try context())
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "Ganit M0 — disposable source / expanded-grid proof"
    let root = NSView(frame: window.contentView!.bounds)
    window.contentView = root
    editor.view.frame = NSRect(x: 0, y: 0, width: 540, height: 620)
    editor.view.autoresizingMask = [.height]
    root.addSubview(editor.view)
    editor.view.isHidden = true
    let projection = try Projection(source)
    preview.frame = NSRect(x: 0, y: 0, width: 540, height: 620)
    preview.autoresizingMask = [.height]
    preview.mapped = projection
    preview.string = projection.text
    preview.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    preview.isEditable = false
    preview.isRichText = false
    preview.textContainerInset = NSSize(width: 20, height: 20)
    preview.setAccessibilityLabel("Sheet with Items table preview; use expanded grid to edit")
    root.addSubview(preview)
    let scroll = NSScrollView(frame: NSRect(x: 540, y: 60, width: 420, height: 560))
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.documentView = grid
    grid.frame = scroll.bounds
    grid.dataSource = self
    grid.delegate = self
    grid.setAccessibilityLabel("Items expanded table prototype")
    for column in fixtureTable().columns {
      let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
      native.title = column.name
      native.width = 130
      grid.addTableColumn(native)
    }
    root.addSubview(scroll)
    let button = NSButton(title: "Return to Sheet", target: self, action: #selector(returnToSheet))
    button.frame = NSRect(x: 570, y: 15, width: 180, height: 32)
    root.addSubview(button)
    editor.sourceDidChange = { [weak self] in
      self?.commits += 1
      self?.grid.reloadData()
      if let self, let projection = try? Projection(self.editor.textView.string) {
        self.preview.mapped = projection
        self.preview.string = projection.text
      }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    Codec.blocks(editor.textView.string).first?.table?.rows.count ?? 0
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let column = tableColumn, let table = Codec.blocks(editor.textView.string).first?.table,
      table.rows.indices.contains(row)
    else { return nil }
    let field = NSTextField()
    field.identifier = column.identifier
    field.tag = row
    field.stringValue =
      table.cells.first {
        $0.key.row == table.rows[row] && $0.key.column == column.identifier.rawValue
      }?.input ?? ""
    field.target = self
    field.action = #selector(commitField(_:))
    field.setAccessibilityLabel("\(column.title), row \(row + 2)")
    return field
  }
  @objc func commitField(_ sender: NSTextField) {
    do {
      try edit(row: sender.tag, column: sender.identifier!.rawValue, input: sender.stringValue)
    } catch { window.title = "M0 diagnostic: \(error)" }
  }
  func edit(row: Int, column: String, input: String) throws {
    guard let block = Codec.blocks(editor.textView.string).first, var table = block.table else {
      throw SpikeFailure(message: "no valid table")
    }
    let key = CellKey(table: table.id, row: table.rows[row], column: column)
    table.bindings.removeAll { $0.owner == key }
    if let index = table.cells.firstIndex(where: { $0.key == key }) {
      table.cells[index].input = input
      table.cells[index].override = true
    } else {
      table.cells.append(Cell(key: key, input: input, override: true))
    }
    try replace(block: block, table: table)
  }
  func replace(block: Block, table: Table) throws {
    editor.textView.breakUndoCoalescing()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(try Codec.encode(table), replacementRange: block.range)
    editor.documentUndoManager.endUndoGrouping()
    editor.textView.breakUndoCoalescing()
    // Inline prototype is source-mapped shading, not a claimed embedded grid.
    if let range = Codec.blocks(editor.textView.string).first?.range {
      editor.textView.textStorage?.addAttribute(
        .backgroundColor,
        value: NSColor.controlAccentColor.withAlphaComponent(0.08), range: range)
    }
  }
  @objc func returnToSheet() {
    preview.isHidden = true
    editor.view.isHidden = false
    window.makeFirstResponder(editor.textView)
    editor.textView.setSelectedRange(savedSelection)
    editor.textView.scrollRangeToVisible(savedSelection)
  }

  func verify(snapshot: String? = nil) throws {
    _ = editor.view
    if let snapshot, let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
      preview.cacheDisplay(in: preview.bounds, to: bitmap)
      if let image = bitmap.representation(using: .png, properties: [:]) {
        try image.write(to: URL(fileURLWithPath: snapshot))
      }
    }
    let source = editor.textView.string
    try check(editor.textView.undoManager === editor.documentUndoManager, "document Undo ownership")
    guard let field = tableView(grid, viewFor: grid.tableColumns[1], row: 2) as? NSTextField,
      let action = field.action
    else { throw SpikeFailure(message: "native grid field") }
    field.stringValue = "99"
    try check(NSApp.sendAction(action, to: field.target, from: field), "native field commit action")
    try check(field.accessibilityLabel() == "Qty, row 4", "native cell accessibility label")
    try check(preview.string.contains("99"), "inline projection refresh after native commit")
    let edited = editor.textView.string
    try check(
      edited != source && editor.sheet.text == edited && commits > 0,
      "grid edit -> source/autosave callback")
    editor.documentUndoManager.undo()
    try check(editor.textView.string == source && editor.sheet.text == source, "grid Undo")
    editor.documentUndoManager.redo()
    try check(editor.textView.string == edited, "grid redo")
    editor.documentUndoManager.undo()
    let block = Codec.blocks(source)[0]
    var deleted = block.table!
    deleted.deleteRow("r-b")
    try replace(block: block, table: deleted)
    let broken = editor.textView.string
    try check(broken.contains("#REF!{t-items/r-b/c-qty}"), "deleted marker")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(broken.utf8).write(to: url, options: .atomic)
    let reopened = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    try check(Codec.blocks(reopened)[0].table == deleted, "broken target save/reload")
    editor.documentUndoManager.undo()
    try check(editor.textView.string == source, "delete Undo restores IDs and bindings")
    let projection = try Projection(source)
    let mapped = projection.canonicalRange(
      NSRange(location: 0, length: projection.text.utf16.count))
    try check(
      mapped == NSRange(location: 0, length: source.utf16.count),
      "projection cross-boundary source map")
    try check(
      !projection.text.contains("\u{fffc}") && !source.contains("\u{fffc}"),
      "no canonical attachments")
    // Cross-boundary copy remains canonical source, with no attachment characters.
    let pasteboard = NSPasteboard.withUniqueName()
    window.makeFirstResponder(editor.textView)
    editor.textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
    let types = editor.textView.writablePasteboardTypes
    pasteboard.declareTypes(types, owner: nil)
    try check(editor.textView.writeSelection(to: pasteboard, types: types), "cross-boundary copy")
    try check(pasteboard.string(forType: types[0]) == source, "copy fidelity")
    try check(preview.mapped?.source == source, "preview restored canonical source after Undo")
    preview.setSelectedRange(NSRange(location: 0, length: preview.string.utf16.count))
    pasteboard.declareTypes(preview.writablePasteboardTypes, owner: nil)
    try check(
      preview.writeSelection(to: pasteboard, types: preview.writablePasteboardTypes),
      "native preview cross-boundary copy")
    try check(
      pasteboard.string(forType: preview.writablePasteboardTypes[0]) == source,
      "preview copy emits canonical source")
    pasteboard.releaseGlobally()
    // Find navigation proof uses the mapped source range. Native Find UI still needs task QA.
    let found = (source as NSString).range(of: "1,25")
    editor.textView.setSelectedRange(found)
    editor.textView.scrollRangeToVisible(found)
    try check(editor.textView.selectedRange() == found, "Find source navigation")
    savedSelection = NSRange(location: 3, length: 0)
    returnToSheet()
    try check(
      window.firstResponder === editor.textView
        && editor.textView.selectedRange() == savedSelection,
      "Return restores prose focus and selection")
    try check(
      grid.accessibilityLabel() != nil && grid.accessibilityRole() == .table,
      "grid accessibility role/label")
    // Marked-text simulation establishes only the controller gate, not real IME coverage.
    editor.textView.setMarkedText(
      "かな", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    try check(editor.textView.hasMarkedText(), "native marked text retained")
    editor.textView.unmarkText()
    window.close()
  }
}
