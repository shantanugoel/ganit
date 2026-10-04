import AppKit
import GanitEngine

/// Applies canonical source edits that are not typed, such as structural
/// table edits, through the same pipeline as typing: the text storage (and so
/// the mirrored `SheetSource`, autosave and evaluation scheduling), the
/// line-reference rewrite and one document Undo step.
///
/// The source is the only store. A table grid is a projection derived from
/// it and is never saved; it changes only by handing this coordinator the
/// patches a `TableSourceDocument` transformation computed. Undo and Redo
/// restore the exact source bytes and the selection around the edit.
@MainActor
final class SheetSourceCoordinator {
  enum Failure: Error, Equatable {
    /// The sheet cannot be edited, such as a sheet in the Trash.
    case notEditable
    /// The patches do not match the current source.
    case staleEdit
  }

  private(set) var isApplying = false
  private unowned let textView: NSTextView
  private let undoManager: UndoManager

  init(textView: NSTextView, undoManager: UndoManager) {
    self.textView = textView
    self.undoManager = undoManager
  }

  /// Replaces UTF-8 ranges of the current source, each expected to hold its
  /// patch's text, as one undoable edit named `actionName`. Every patch
  /// applies, or none does.
  func apply(_ patches: [TableSourcePatch], actionName: String) throws {
    guard !patches.isEmpty else { return }
    isApplying = true
    defer { isApplying = false }
    guard textView.isEditable, let storage = textView.textStorage else {
      throw Failure.notEditable
    }
    // An open composition is committed first, so it cannot land inside a
    // replaced range afterwards.
    if textView.hasMarkedText() { textView.unmarkText() }
    let text = textView.string
    guard (try? TableSourcePatch.applying(patches, to: text)) != nil,
      let changes = Self.utf16Changes(patches, in: text)
    else { throw Failure.staleEdit }

    let before = textView.selectedRange()
    textView.breakUndoCoalescing()
    undoManager.beginUndoGrouping()
    defer {
      undoManager.setActionName(actionName)
      undoManager.endUndoGrouping()
      textView.breakUndoCoalescing()
    }
    // Registered first, so Undo runs it last: after the source is restored.
    registerSelection(undo: before, redo: nil)
    guard
      textView.shouldChangeText(
        inRanges: changes.map { NSValue(range: $0.range) },
        replacementStrings: changes.map(\.replacement))
    else { throw Failure.notEditable }
    // Back to front, so earlier ranges keep their offsets. Each replacement
    // is mirrored into the sheet, saved and evaluated as a typed one is.
    for change in changes.reversed() {
      storage.replaceCharacters(in: change.range, with: change.replacement)
    }
    textView.setSelectedRange(Self.mapped(before, through: changes))
    // Rewrites line references the edit moved, inside this Undo group.
    textView.didChangeText()
    // Registered last, so Redo runs it last: after the source is replayed.
    registerSelection(undo: nil, redo: textView.selectedRange())
  }

  /// A selection step for Undo and Redo: undoing it selects `undo`, and
  /// redoing it selects `redo`. A `nil` range leaves the selection to the
  /// text system.
  private func registerSelection(undo: NSRange?, redo: NSRange?) {
    undoManager.registerUndo(withTarget: self) { coordinator in
      if let undo { coordinator.select(undo) }
      coordinator.registerSelection(undo: redo, redo: undo)
    }
  }

  private func select(_ range: NSRange) {
    let length = (textView.string as NSString).length
    let location = min(range.location, length)
    textView.setSelectedRange(
      NSRange(location: location, length: min(range.length, length - location)))
  }

  /// Patches as ascending UTF-16 ranges of `text`, or `nil` when one splits
  /// a Unicode scalar.
  static func utf16Changes(_ patches: [TableSourcePatch], in text: String)
    -> [(range: NSRange, replacement: String)]?
  {
    let utf8 = text.utf8
    func offset(_ utf8Offset: Int) -> Int? {
      guard
        let index = utf8.index(utf8.startIndex, offsetBy: utf8Offset, limitedBy: utf8.endIndex),
        index.samePosition(in: text.unicodeScalars) != nil
      else { return nil }
      return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
    var changes: [(range: NSRange, replacement: String)] = []
    for patch in patches.sorted(by: { $0.utf8Range.lowerBound < $1.utf8Range.lowerBound }) {
      guard let lower = offset(patch.utf8Range.lowerBound),
        let upper = offset(patch.utf8Range.upperBound)
      else { return nil }
      changes.append((NSRange(location: lower, length: upper - lower), patch.replacement))
    }
    return changes
  }

  /// A selection carried through ascending changes: it moves with the text
  /// before it, and an end inside a replaced range moves to that range's
  /// start.
  static func mapped(_ selection: NSRange, through changes: [(range: NSRange, replacement: String)])
    -> NSRange
  {
    func location(_ offset: Int) -> Int {
      var delta = 0
      for (range, replacement) in changes {
        if range.upperBound <= offset {
          delta += (replacement as NSString).length - range.length
        } else if range.location < offset {
          return range.location + delta
        }
      }
      return offset + delta
    }
    let start = location(selection.location)
    return NSRange(location: start, length: max(0, location(selection.upperBound) - start))
  }
}

/// Structural table edits as document edits. Each computes its patches from
/// the current canonical source and applies them as one Undo step; the
/// expanded grid calls these rather than editing a projection.
extension SheetEditorViewController {
  /// Applies the edit `transform` computes from the current source. Throws
  /// the transformation's error, leaving the source unchanged.
  @discardableResult
  package func editTables(
    _ actionName: String, _ transform: (TableSourceDocument) throws -> TableSourceEdit
  ) throws -> TableSourceEdit {
    let edit = try transform(TableSourceDocument(sheet))
    try sourceCoordinator.apply(edit.patches, actionName: actionName)
    return edit
  }

  /// Inserts a new table block at a line start, returning its identity.
  @discardableResult
  package func createTable(
    named name: String, headers: [(String, TableInputPolicy)], rowCount: Int, atUTF8 offset: Int
  ) throws -> TableID? {
    try editTables(localized("table.undo.insertTable", "Insert Table")) {
      try $0.createTable(name: name, headers: headers, rowCount: rowCount, atUTF8: offset)
    }.createdTable
  }

  @discardableResult
  package func duplicateTable(_ id: TableID, named name: String, atUTF8 offset: Int) throws
    -> TableID?
  {
    try editTables(localized("table.undo.duplicateTable", "Duplicate Table")) {
      try $0.duplicateTable(id, named: name, atUTF8: offset)
    }.createdTable
  }

  /// Removes the table's block. References to it from other tables and
  /// from prose become broken markers in the same Undo step, so no table is
  /// left reading a table that is gone, and a new table with its name does
  /// not take its place.
  package func deleteTable(_ id: TableID) throws {
    let configuration = lexingConfiguration
    try editTables(localized("table.undo.deleteTable", "Delete Table")) {
      try $0.deleteTable(id, configuration: configuration)
    }
  }

  package func insertTableRows(_ id: TableID, at index: Int, count: Int = 1) throws {
    try editTables(localized("table.undo.insertRows", "Insert Rows")) {
      try $0.insertRows(table: id, at: index, count: count)
    }
  }

  package func appendTableRows(_ id: TableID, count: Int = 1) throws {
    try editTables(localized("table.undo.insertRows", "Insert Rows")) {
      try $0.appendRows(table: id, count: count)
    }
  }

  package func deleteTableRows(_ id: TableID, in range: Range<Int>) throws {
    try editTables(localized("table.undo.deleteRows", "Delete Rows")) {
      try $0.deleteRows(table: id, in: range)
    }
  }

  package func insertTableColumn(
    _ id: TableID, at index: Int, header: String, policy: TableInputPolicy = .value
  ) throws {
    try editTables(localized("table.undo.insertColumn", "Insert Column")) {
      try $0.insertColumn(table: id, at: index, header: header, policy: policy)
    }
  }

  package func deleteTableColumns(_ id: TableID, in range: Range<Int>) throws {
    try editTables(localized("table.undo.deleteColumns", "Delete Columns")) {
      try $0.deleteColumns(table: id, in: range)
    }
  }

  package func renameTable(_ id: TableID, to name: String) throws {
    try editTables(localized("table.undo.renameTable", "Rename Table")) {
      try $0.renameTable(id, to: name)
    }
  }

  package func renameTableColumn(_ id: TableID, column: ColumnID, to header: String) throws {
    try editTables(localized("table.undo.renameColumn", "Rename Column")) {
      try $0.renameColumn(table: id, column: column, to: header)
    }
  }

  /// `nil` clears the cell's record; `""` is a blank override.
  package func setTableCell(_ id: TableID, at position: TableCellPosition, source: String?)
    throws
  {
    try editTables(localized("table.undo.editCell", "Edit Cell")) {
      try $0.setCell(table: id, at: position, source: source)
    }
  }

  package func setTableColumnRule(_ id: TableID, column: ColumnID, formula: String?) throws {
    try editTables(localized("table.undo.columnRule", "Change Column Formula")) {
      try $0.setColumnRule(table: id, column: column, source: formula)
    }
  }

  package func setTableColumnTotal(_ id: TableID, column: ColumnID, total: TableTotal?) throws {
    try editTables(localized("table.undo.columnTotal", "Change Total")) {
      try $0.setColumnTotal(table: id, column: column, total: total)
    }
  }

  package func setTableColumnInput(
    _ id: TableID, column: ColumnID, policy: TableInputPolicy, unit: String? = nil,
    currency: String? = nil
  ) throws {
    try editTables(localized("table.undo.columnInput", "Change Column Input")) {
      try $0.setColumnInput(
        table: id, column: column, policy: policy, unit: unit, currency: currency)
    }
  }

  package func copyTableCell(
    _ id: TableID, from origin: TableCellPosition, to destination: TableCellPosition
  ) throws {
    try editTables(localized("table.undo.paste", "Paste")) {
      try $0.copyCell(table: id, from: origin, to: destination)
    }
  }

  package func pasteTableCells(
    _ clipboard: TableClipboardRange, into id: TableID, at destination: TableCellPosition
  ) throws {
    try editTables(localized("table.undo.paste", "Paste")) {
      try $0.paste(clipboard, table: id, at: destination)
    }
  }

  /// `formulas` records the reader's explicit choice to enter fields that
  /// start with `=` as formulas.
  package func pasteTablePlainText(
    _ text: String, into id: TableID, at destination: TableCellPosition, formulas: Bool
  ) throws {
    try editTables(localized("table.undo.paste", "Paste")) {
      try $0.pastePlainText(text, table: id, at: destination, formulas: formulas)
    }
  }

  package func fillTableCells(
    _ id: TableID, from origin: TableCellPosition, into rectangle: TableCellRectangle
  ) throws {
    try editTables(localized("table.undo.fill", "Fill")) {
      try $0.fill(table: id, from: origin, into: rectangle)
    }
  }

  package func moveTableCells(
    _ id: TableID, rectangle: TableCellRectangle, to destination: TableCellPosition
  ) throws {
    try editTables(localized("table.undo.moveCells", "Move Cells")) {
      try $0.move(table: id, rectangle: rectangle, to: destination)
    }
  }
}

extension SheetEditorViewController {
  package func replaceTableSource(before: String, after: String, action: String) throws {
    guard before == sheet.text else { throw SheetSourceCoordinator.Failure.staleEdit }
    guard !before.utf8.elementsEqual(after.utf8) else { return }
    try sourceCoordinator.apply(
      [TableSourcePatch(utf8Range: 0..<before.utf8.count, expected: before, replacement: after)],
      actionName: action)
  }
}
