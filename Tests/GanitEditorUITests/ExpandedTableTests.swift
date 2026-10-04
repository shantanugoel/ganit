import AppKit
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

@MainActor
@Suite(.serialized)
struct ExpandedTableTests {
  static var windows: [NSWindow] = []
  func makeEditor(rows: Int = 3) async throws -> (
    SheetEditorViewController, TableModel, ExpandedTableViewController
  ) {
    let table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: rows)
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0),
      calendar: Calendar(identifier: .gregorian), timeZone: #require(TimeZone(identifier: "UTC")))
    let editor = SheetEditorViewController(
      text: "rate = 3\n" + (try TableSourceDocument.canonicalBlock(for: table)) + "rate * 2\n",
      context: context)
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 450), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    editor.openTable(table.id)
    window.layoutIfNeeded()
    return (editor, table, try #require(editor.expandedTable))
  }
  @Test func gridReusesViewsAndHasBoundedRows() async throws {
    let (_, _, grid) = try await makeEditor(rows: 500)
    #expect(grid.grid.numberOfRows == 500)
    #expect(grid.grid.tableColumns.count == 3)
    #expect(grid.grid.subviews.count < 200)
    #expect(grid.formula.accessibilityLabel() == "Cell input or formula")
  }
  @Test func editCancelAndOneDocumentUndo() async throws {
    let (editor, table, grid) = try await makeEditor()
    let original = editor.sheet.text
    grid.beginEditing()
    grid.formula.stringValue = "7"
    grid.cancelEditing()
    #expect(editor.sheet.text == original)
    grid.beginEditing()
    grid.formula.stringValue = "7"
    #expect(grid.commitCellEditing())
    #expect(grid.result == nil)
    await editor.scheduler?.waitUntilIdle()
    #expect(
      grid.display(grid.result?.value(row: table.rows[0], column: table.columns[0].id)) == "7")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == original)
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    await editor.scheduler?.waitUntilIdle()
    #expect(
      grid.display(grid.result?.value(row: table.rows[0], column: table.columns[0].id)) == "7")
  }
  @Test func markedInputCannotCommitOrPick() async throws {
    let (editor, _, grid) = try await makeEditor()
    let source = editor.sheet.text
    grid.beginEditing()
    let input = try #require(grid.formula.currentEditor() as? NSTextView)
    input.setMarkedText(
      "=に", selectedRange: NSRange(location: 2, length: 0), replacementRange: input.selectedRange())
    #expect(!grid.commitCellEditing())
    grid.pickReference(.init(row: 1, column: 1))
    #expect(input.hasMarkedText())
    #expect(editor.sheet.text == source)
    grid.cancelEditing()
    #expect(editor.sheet.text == source)
  }
  @Test func referencePickAndDragKeepDraftAndFocus() async throws {
    let (editor, _, grid) = try await makeEditor()
    let original = editor.sheet.text
    grid.beginEditing()
    let input = try #require(grid.formula.currentEditor() as? NSTextView)
    input.string = "=sum()"
    input.setSelectedRange(NSRange(location: 5, length: 0))
    grid.pickReference(.init(row: 0, column: 0))
    grid.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: grid.formula))
    grid.pickReference(.init(row: 1, column: 0), dragging: true)
    #expect(input.string == "=sum(A2:A3)")
    #expect(grid.isEditingCell)
    #expect(!grid.grid.acceptsFirstResponder)
    #expect(grid.position == .init(row: 0, column: 0))
    #expect(editor.sheet.text == original)
    #expect(grid.referencedCells.count == 2)
    grid.cancelEditing()
  }
  @Test func rectangleAndInvalidReferencesAreSafe() async throws {
    let (_, _, grid) = try await makeEditor()
    grid.select(.init(row: 2, column: 1), extending: true)
    #expect(grid.rectangle.rows == 0..<3)
    #expect(grid.rectangle.columns == 0..<2)
    #expect(grid.projection?.referencedCells(in: "=sum(Z99:ZZ100)").isEmpty == true)
    #expect(grid.projection?.referencedCells(in: "=sum(A1:B1)").isEmpty == true)
  }
  @Test func selectionFollowsIdentityAndStaleDraftDoesNotOverwrite() async throws {
    let (editor, table, grid) = try await makeEditor()
    grid.select(.init(row: 1, column: 1))
    try editor.insertTableRows(table.id, at: 0)
    #expect(grid.position.row == 2)
    grid.beginEditing()
    grid.formula.stringValue = "8"
    try editor.setTableCell(table.id, at: grid.position, source: "9")
    #expect(!grid.commitCellEditing())
    grid.cancelEditing()
    #expect(grid.formula.stringValue == "9")
  }
  @Test func pendingInputNeverShowsEarlierResult() async throws {
    let (editor, table, grid) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "2")
    #expect(grid.result == nil)
    await editor.scheduler?.waitUntilIdle()
    #expect(
      grid.display(grid.result?.value(row: table.rows[0], column: table.columns[0].id)) == "2")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "3")
    #expect(grid.result == nil)
    #expect(grid.display(nil) == "Pending…")
  }
  @Test func rulesOverridesResetAndEmptyTables() async throws {
    let (editor, table, grid) = try await makeEditor()
    try editor.setTableColumnRule(table.id, column: table.columns[1].id, formula: "=A2 * rate")
    try editor.pasteTablePlainText(
      "2\n4\n6", into: table.id, at: .init(row: 0, column: 0), formulas: false)
    grid.select(.init(row: 1, column: 1))
    await editor.scheduler?.waitUntilIdle()
    #expect(grid.formula.stringValue == "=A3 * rate")
    grid.beginEditing()
    #expect(grid.formula.stringValue == "=A3 * rate")
    grid.formula.stringValue = "7"
    #expect(grid.commitCellEditing())
    #expect(grid.projection?.isOverride(at: grid.position) == true)
    grid.resetOverrides()
    #expect(grid.projection?.isOverride(at: grid.position) == false)
    await editor.scheduler?.waitUntilIdle()
    #expect(
      grid.display(grid.result?.value(row: table.rows[1], column: table.columns[1].id)) == "12")
    try editor.deleteTableRows(table.id, in: 0..<3)
    #expect(grid.grid.numberOfRows == 0)
    grid.addRow()
    #expect(grid.grid.numberOfRows == 1)
  }
  @Test func clipboardTranslatesFormulasAndRejectsImplicitExternalFormula() async throws {
    let (editor, table, grid) = try await makeEditor()
    editor.resultPasteboard = NSPasteboard.withUniqueName()
    defer { editor.resultPasteboard.releaseGlobally() }
    try editor.pasteTablePlainText(
      "2\t=A2 * 3\n4", into: table.id, at: .init(row: 0, column: 0), formulas: true)
    grid.select(.init(row: 0, column: 1))
    grid.copyFormulas()
    grid.select(.init(row: 1, column: 1))
    grid.pasteCells()
    #expect(grid.projection?.source(at: grid.position) == "=A3 * 3")
    editor.resultPasteboard.clearContents()
    editor.resultPasteboard.setString("=A2 * 5", forType: .string)
    let before = editor.sheet.text
    grid.pasteCells()
    #expect(editor.sheet.text == before)
    grid.pasteFormulas()
    #expect(grid.projection?.source(at: grid.position) == "=A2 * 5")
  }
  @Test func typedTotalsAndFullPrecisionCopy() async throws {
    let (editor, table, grid) = try await makeEditor()
    editor.resultPasteboard = NSPasteboard.withUniqueName()
    defer { editor.resultPasteboard.releaseGlobally() }
    try editor.pasteTablePlainText(
      "2 USD\n4 USD", into: table.id, at: .init(row: 0, column: 0), formulas: false)
    try editor.setTableColumnTotal(table.id, column: table.columns[0].id, total: .sum)
    await editor.scheduler?.waitUntilIdle()
    grid.select(.init(row: 1, column: 0), extending: true)
    #expect(grid.status.stringValue.contains("$6.00"))
    #expect(grid.status.stringValue.contains("Sum:"))
    grid.copyFullPrecision(nil)
    #expect(editor.resultPasteboard.string(forType: .string)?.contains("USD") == true)
  }
  @Test func returnRestoresProseAndReopenRestoresSelection() async throws {
    let (editor, table, grid) = try await makeEditor()
    editor.textView.setSelectedRange(NSRange(location: 3, length: 2))
    grid.select(.init(row: 2, column: 1))
    editor.returnFromTable(nil)
    #expect(editor.expandedTable == nil)
    #expect(editor.textView.selectedRange() == NSRange(location: 3, length: 2))
    editor.openTable(table.id)
    #expect(editor.expandedTable?.position == .init(row: 2, column: 1))
  }
  @Test func projectionObserversReceiveSourceAndEvaluation() async throws {
    let (editor, table, grid) = try await makeEditor()
    let second = ExpandedTableViewController(editor: editor, table: table.id)
    second.loadViewIfNeeded()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "11")
    #expect(second.projection?.source(at: .init(row: 0, column: 0)) == "11")
    #expect(grid.result == nil && second.result == nil)
    await editor.scheduler?.waitUntilIdle()
    #expect(
      second.display(second.result?.value(row: table.rows[0], column: table.columns[0].id)) == "11")
    editor.tableProjectionObservers[second.observerID] = nil
  }
  @Test func toolbarDoesNotCoverFormulaControls() async throws {
    let (editor, _, grid) = try await makeEditor()
    let window = try #require(editor.view.window)
    window.styleMask.insert(.fullSizeContentView)
    window.toolbar = NSToolbar(identifier: "M4 test")
    window.setContentSize(NSSize(width: 400, height: 450))
    window.layoutIfNeeded()
    grid.view.layoutSubtreeIfNeeded()
    let input = grid.formula.convert(grid.formula.bounds, to: nil)
    #expect(input.maxY <= window.contentLayoutRect.maxY)
    #expect(input.minX >= 0)
    #expect(input.maxX <= window.contentLayoutRect.maxX)
    #expect(grid.grid.selectedRowIndexes.isEmpty)
    #expect(grid.position.row == 0)
  }
  @Test func resetOverridesPreservesOrdinaryInputs() async throws {
    let (editor, table, grid) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "2")
    grid.resetOverrides()
    #expect(grid.projection?.source(at: .init(row: 0, column: 0)) == "2")
  }

  @Test func brokenReferenceRepairReplacesTheCompleteOperand() async throws {
    let (editor, table, grid) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 2, column: 1), source: "=A2 * 3")
    try editor.deleteTableRows(table.id, in: 0..<1)
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "4")
    await editor.scheduler?.waitUntilIdle()
    grid.select(.init(row: 1, column: 1))
    #expect(grid.formula.stringValue.contains("#REF!"))
    grid.repairReference()
    grid.pickReference(.init(row: 0, column: 0))
    #expect(grid.formula.stringValue == "=A2 * 3")
    #expect(grid.commitCellEditing())
    await editor.scheduler?.waitUntilIdle()
    #expect(
      grid.display(grid.result?.value(row: table.rows[2], column: table.columns[1].id)) == "12")
  }
  @Test func blockedCellNavigatesToOriginalFailure() async throws {
    let (editor, table, grid) = try await makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "=1 / 0")
    try editor.setTableCell(table.id, at: .init(row: 1, column: 1), source: "=A2 * 2")
    await editor.scheduler?.waitUntilIdle()
    grid.select(.init(row: 1, column: 1))
    let before = editor.sheet.text
    grid.goToOriginalFailure()
    #expect(editor.expandedTable?.position == .init(row: 0, column: 0))
    #expect(editor.sheet.text == before)
  }

}
