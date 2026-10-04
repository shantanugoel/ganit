import AppKit
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

@MainActor
@Suite(.serialized)
struct TableReviewRegressionTests {
  @Test func previewUndoRestoresSourceResultsAndExportAfterEnterAndEscape() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    let preview = try #require(editor.inlineTableViews[table.id])
    let cell = try #require(
      preview.cells.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 0 })
    cell.performClick(nil)
    preview.beginPreviewEdit()
    preview.cellInput.stringValue = "42"
    let before = editor.sheet.text
    let field = try #require(preview.cellInput.currentEditor() as? NSTextView)
    #expect(
      preview.control(
        preview.cellInput, textView: field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    let next = try #require(preview.cellInput.currentEditor() as? NSTextView)
    #expect(
      preview.control(
        preview.cellInput, textView: next, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    let edited = editor.sheet.text
    editor.textView.undoManager?.undo()
    #expect(editor.sheet.text == before)
    await editor.scheduler?.waitUntilIdle()
    editor.openTable(table.id)
    let grid = try #require(editor.expandedTable)
    #expect(grid.exportGrid(mode: .formulas).rows[0][0] == "")
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == edited)
    await editor.scheduler?.waitUntilIdle()
    let csv = TableGridText.text(
      grid.exportGrid(mode: .values), format: .csv, locale: .init(identifier: "en-US"))
    let file = URL(fileURLWithPath: "/tmp/ganit-review-undo.csv")
    try csv.write(to: file, atomically: true, encoding: .utf8)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("42"))
  }
  @Test func incrementalFindKeepsFocusAndNeverOpensTable() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "BETA")
    let text = try #require(editor.textView as? SheetTextView)
    let search = NSSearchField(string: "BET")
    editor.view.addSubview(search)
    editor.view.window?.makeFirstResponder(search)
    let responder = editor.view.window?.firstResponder
    let client = MappedTableFindClient(textView: text)
    client.scrollRangeToVisible((text.string as NSString).range(of: "BETA"))
    await Task.yield()
    #expect(editor.expandedTable == nil)
    #expect(editor.view.window?.firstResponder === responder)
    let preview = try #require(editor.inlineTableViews[table.id])
    #expect(preview.selectedCell == .init(row: 0, column: 0))
    #expect(preview.inspection.stringValue.contains("Items · A2 · Qty: BETA"))
    preview.open.performClick(nil)
    #expect(editor.expandedTable?.position == .init(row: 0, column: 0))
  }
  @Test func automaticLabelsAndCalculatorArithmeticUseOneEntryFlow() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableColumnInput(table.id, column: table.columns[0].id, policy: .automatic)
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "Rice")
    controller.select(.init(row: 0, column: 1))
    controller.beginEditing()
    controller.formula.stringValue = "85 USD * 3"
    #expect(controller.commitCellEditing())
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.cellDisplay(row: 0, column: 0) == "Rice")
    #expect(controller.effectiveSource(at: .init(row: 0, column: 1)) == "=85 USD * 3")
    #expect(controller.cellDisplay(row: 0, column: 1).contains("255"))
  }
  @Test func fullPreviewHasAllRowsColumnsAndOverrideState() async throws {
    let (editor, table, _) = try await ExpandedTableTests().makeEditor(rows: 6)
    for index in 2..<9 {
      try editor.insertTableColumn(table.id, at: index, header: "Column \(index)")
    }
    try editor.setTableColumnRule(table.id, column: table.columns[1].id, formula: "=1")
    try editor.setTableCell(table.id, at: .init(row: 5, column: 1), source: "10%")
    editor.returnFromTable(nil)
    await editor.scheduler?.waitUntilIdle()
    let preview = try #require(editor.inlineTableViews[table.id])
    let buttons = preview.cells.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 54)
    #expect(buttons.contains { $0.title == "10% •" })
    #expect(preview.scroll.hasVerticalScroller)
  }
  @Test func textAndBlankSelectionHaveNoAggregateAndFillKeepsRange() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableColumnInput(table.id, column: table.columns[0].id, policy: .text)
    try editor.setTableCell(table.id, at: .init(row: 0, column: 0), source: "Rice")
    await editor.scheduler?.waitUntilIdle()
    controller.select(.init(row: 0, column: 0))
    #expect(controller.status.stringValue.contains("1 cell"))
    #expect(!controller.status.stringValue.contains("Sum:"))
    #expect(controller.status.stringValue.contains("1 text"))
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=2 * 3")
    controller.select(.init(row: 0, column: 1))
    controller.select(.init(row: 2, column: 1), extending: true)
    controller.fillDown()
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.rectangle.rows == 0..<3)
    #expect(controller.status.stringValue.contains("B2:B4"))
    #expect(controller.status.stringValue.contains("Sum: 18"))
  }
  @Test func percentageDisplayKeepsRatioAndDecimalsThroughReload() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=1 / 10")
    try editor.editTables("Format Percentage") {
      try $0.setColumnPresentation(
        table: table.id, column: table.columns[1].id, percentageDecimals: 2)
    }
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.cellDisplay(row: 0, column: 1) == "10.00%")
    let reloaded = try #require(
      TableEditingSnapshot(TableSourceDocument(editor.sheet.text), id: table.id))
    #expect(reloaded.columns[1].percentageDecimals == 2)
    #expect(reloaded.source(at: .init(row: 0, column: 1)) == "=1 / 10")
    let grid = TableGridText.grid(
      try #require(controller.result),
      formatter: ResultFormatter(context: editor.tableEvaluationContext),
      diagnostics: DiagnosticFormatter(context: editor.tableEvaluationContext))
    #expect(grid.rows[0][1] == "10.00%")
  }
  @Test func stableSortAndFilterKeepTargetsTotalsAndUndo() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    for (row, source) in ["10", "-10", "10"].enumerated() {
      try editor.setTableCell(table.id, at: .init(row: row, column: 0), source: source)
    }
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=A3")
    let before = editor.sheet.text
    controller.select(.init(row: 0, column: 0))
    controller.sortAscending()
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.displayedRows == [1, 0, 2])
    #expect(controller.projection?.rows == table.rows)
    #expect(controller.effectiveSource(at: .init(row: 0, column: 1)) == "=A3")
    #expect(controller.cellDisplay(row: 0, column: 1) == "-10")
    controller.setReview(sort: "ascending", filter: "-", frozen: true)
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.displayedRows == [1])
    #expect(controller.status.stringValue.contains("2 hidden rows"))
    #expect(!controller.frozenScroll.isHidden)
    editor.documentUndoManager.undo()
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func mixedCurrenciesGetSeparateTotals() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.pasteTablePlainText(
      "1 USD\n2 EUR\n3 INR", into: table.id, at: .init(row: 0, column: 0), formulas: false)
    try editor.setTableColumnTotal(table.id, column: table.columns[0].id, total: .sum)
    await editor.scheduler?.waitUntilIdle()
    let total = controller.totalDisplay(column: 0)
    #expect(total.contains("USD:"))
    #expect(total.contains("EUR:"))
    #expect(total.contains("INR:"))
    #expect(!total.contains("Error"))
    #expect(controller.grid.numberOfRows == 4)
  }
  @Test func unsupportedPartsAreNamedInDetailsCopyAndExport() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=IF(A2 > 1000, 1, 0)")
    try editor.setTableCell(table.id, at: .init(row: 1, column: 1), source: "=SUM(A2:A3, A4:A4)")
    await editor.scheduler?.waitUntilIdle()
    let problem = try #require(controller.cellProblem(row: 0, column: 1))
    #expect(problem.contains("not supported"))
    #expect(!problem.contains("references"))
    #expect(controller.cellProblem(row: 1, column: 1)?.contains("one range") == true)
    #expect(controller.exportGrid(mode: .values).rows[0][1] == problem)
    #expect(controller.errorReport().rows.count == 2)
  }
  @Test func invalidColumnRuleCannotApplyAndDefinitionsAreAvailable() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.pasteTablePlainText(
      "1\n2\n3", into: table.id, at: .init(row: 0, column: 0), formulas: false)
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.result?.noteDefinitions.contains { $0.0 == "rate" } == true)
    let before = editor.sheet.text
    #expect(!controller.rulePreview(column: table.columns[1].id, source: "=Qty * rate").0)
    let valid = controller.rulePreview(column: table.columns[1].id, source: "=[@Qty] * rate")
    #expect(valid.0)
    #expect(valid.1.contains("3"))
    #expect(editor.sheet.text == before)
  }
  @Test func conversionReplacesSelectedListInOneUndoStep() async throws {
    let (editor, _) = try await InlineTableTests().makeEditor()
    let original = "Item\tQty\nRice\t2\nMilk\t3\n"
    editor.textView.selectAll(nil)
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(original, replacementRange: editor.textView.selectedRange())
    editor.documentUndoManager.endUndoGrouping()
    let before = editor.sheet.text
    let id = try #require(
      try editor.insertTableRectangle(
        named: "Trip", headers: [("Item", .automatic), ("Qty", .automatic)],
        rows: [["Rice", "2"], ["Milk", "3"]], formulas: false, atUTF8: 0, expectedSource: before,
        replacing: NSRange(location: 0, length: (before as NSString).length)))
    #expect(!editor.sheet.text.hasSuffix(original))
    #expect(TableEditingSnapshot(TableSourceDocument(editor.sheet), id: id)?.rows.count == 2)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }
  @Test func accessibilityUsesDocumentMeaningAndActualCellSelection() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    let text = try #require(editor.textView as? SheetTextView)
    let value = try #require(text.accessibilityValue())
    #expect(value.contains("Table Items"))
    #expect(!value.contains("@ganit-table"))
    #expect(!value.contains(table.id.uuid.uuidString.lowercased()))
    editor.openTable(table.id)
    let grid = try #require(editor.expandedTable)
    grid.select(.init(row: 0, column: 1))
    #expect(grid.grid.selectedRowIndexes.isEmpty)
  }
  @Test func sortedNavigationAndFilteredDeletionUseVisibleRowIdentities() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    for (row, source) in ["30", "10", "20"].enumerated() {
      try editor.setTableCell(table.id, at: .init(row: row, column: 0), source: source)
    }
    try editor.editTables("Sort") {
      try $0.setColumnReview(
        table: table.id, column: table.columns[0].id, sort: "ascending", filter: nil, frozen: false)
    }
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.displayedRows == [1, 2, 0])
    controller.select(.init(row: 1, column: 1))
    controller.moveAfterCommit(horizontal: true, backwards: false)
    #expect(controller.position == .init(row: 2, column: 0))
    controller.moveAfterCommit(horizontal: false, backwards: false)
    #expect(controller.position.row == 0)
    controller.moveAfterCommit(horizontal: false, backwards: false)
    #expect(controller.projection?.rows.count == 3)
    try editor.editTables("Filter") {
      try $0.setColumnReview(
        table: table.id, column: table.columns[0].id, sort: "ascending", filter: "0", frozen: false)
    }
    await editor.scheduler?.waitUntilIdle()
    controller.select(.init(row: 1, column: 0))
    controller.select(.init(row: 2, column: 0), extending: true)
    #expect(controller.selectionRows == [1, 2])
    controller.clearCells()
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.effectiveSource(at: .init(row: 0, column: 0)) == "30")
    editor.documentUndoManager.undo()
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.effectiveSource(at: .init(row: 2, column: 0)) == "20")
  }

  @Test func mixedSortGroupsAndOneFrozenColumnSurviveReload() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor(rows: 6)
    for (row, source) in ["20 USD", "3 EUR", "10 USD", "1 EUR", "", "bad"].enumerated() {
      try editor.setTableCell(table.id, at: .init(row: row, column: 0), source: source)
    }
    try editor.editTables("Review") {
      try $0.setColumnReview(
        table: table.id, column: table.columns[0].id, sort: "ascending", filter: nil, frozen: true)
    }
    await editor.scheduler?.waitUntilIdle()
    #expect(controller.displayedRows == [2, 0, 3, 1, 4, 5])
    try editor.editTables("Freeze") {
      try $0.setColumnReview(
        table: table.id, column: table.columns[1].id, sort: nil, filter: nil, frozen: true)
    }
    let reloaded = try #require(
      TableEditingSnapshot(TableSourceDocument(editor.sheet), id: table.id))
    #expect(!reloaded.columns[0].frozen)
    #expect(reloaded.columns[1].frozen)
    #expect(reloaded.columns[0].reviewSort == "ascending")
  }

  @Test func nativeAccessibilityInterfacesHideTableStorage() async throws {
    let (editor, _) = try await InlineTableTests().makeEditor()
    let text = try #require(editor.textView as? SheetTextView)
    let value = try #require(text.accessibilityValue())
    #expect(!value.contains("@ganit-table"))
    let range = NSRange(location: 0, length: (text.string as NSString).length)
    let string = try #require(
      text.accessibilityString(for: range))
    #expect(string.contains("Table Items"))
    #expect(!string.contains("@ganit-table"))
  }

  @Test func previewOverrideInspectionAndRestoreShareDocumentUndo() async throws {
    let (editor, table, _) = try await ExpandedTableTests().makeEditor()
    try editor.setTableColumnRule(table.id, column: table.columns[1].id, formula: "=2 * 3")
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "10%")
    editor.returnFromTable(nil)
    await editor.scheduler?.waitUntilIdle()
    let preview = try #require(editor.inlineTableViews[table.id])
    let button = try #require(
      preview.cells.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 1 })
    button.performClick(nil)
    #expect(preview.inspection.stringValue.contains("Overrides column formula: =2 * 3"))
    #expect(preview.inspection.stringValue.contains("Cell input: 10%"))
    #expect(preview.inspection.stringValue.contains("Restore Column Formula"))
    let before = editor.sheet.text
    preview.restoreColumnFormula()
    await editor.scheduler?.waitUntilIdle()
    let restored = try #require(
      TableEditingSnapshot(TableSourceDocument(editor.sheet), id: table.id))
    #expect(!restored.isOverride(at: .init(row: 0, column: 1)))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == before)
  }

  @Test func sheetPreviewStaysInInputColumnAndKeepsHorizontalScrollControl() async throws {
    let (editor, table) = try await InlineTableTests().makeEditor()
    let text = try #require(editor.textView as? SheetTextView)
    for width: CGFloat in [360, 640, 1200] {
      text.setFrameSize(.init(width: width, height: 1400))
      text.textLayoutManager?.ensureLayout(
        for: text.textLayoutManager!.textContentManager!.documentRange)
      editor.layoutInlineTables()
      let preview = try #require(editor.inlineTableViews[table.id])
      preview.layoutSubtreeIfNeeded()
      #expect(preview.frame.width <= text.textContainer!.size.width)
      if let separator = text.answerSeparatorX {
        #expect(preview.frame.maxX <= separator)
      }
      #expect(preview.scroll.scrollerStyle == .legacy)
      #expect(!preview.scroll.autohidesScrollers)
      #expect(preview.scroll.horizontalScroller != nil)
    }
  }

  @Test func accessibleSelectionFollowsSortedRowsAndSpeaksFullProblems() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    for (row, source) in ["30", "10", "20"].enumerated() {
      try editor.setTableCell(table.id, at: .init(row: row, column: 0), source: source)
    }
    try editor.setTableCell(table.id, at: .init(row: 2, column: 1), source: "=1 / 0")
    controller.select(.init(row: 0, column: 0))
    controller.sortAscending()
    await editor.scheduler?.waitUntilIdle()
    controller.select(.init(row: 2, column: 1))
    controller.select(.init(row: 0, column: 1), extending: true)
    #expect(controller.selectionRows == [2, 0])
    #expect(controller.status.stringValue.contains("Rows 4, 2 · Columns B:B"))
    #expect(controller.status.stringValue.contains("2 rows × 1 columns"))
    #expect(controller.status.stringValue.contains("Copy starts: B4"))
    #expect(!controller.status.stringValue.contains("B2:B4"))
    let column = controller.grid.tableColumns[2]
    let unselected = try #require(
      controller.tableView(controller.grid, viewFor: column, row: 0) as? TableGridCellView)
    let failed = try #require(
      controller.tableView(controller.grid, viewFor: column, row: 1) as? TableGridCellView)
    #expect(!unselected.isAccessibilitySelected())
    #expect(failed.isAccessibilitySelected())
    let problem = try #require(controller.cellProblem(row: 2, column: 1))
    #expect(failed.accessibilityLabel()?.contains(problem) == true)
    editor.returnFromTable(nil)
    await editor.scheduler?.waitUntilIdle()
    let text = try #require(editor.textView as? SheetTextView)
    text.setSelectedRange(.init(location: 0, length: text.string.utf16.count))
    #expect(text.accessibilitySelectedText()?.contains("@ganit-table") == false)
    let preview = try #require(editor.inlineTableViews[table.id])
    #expect(
      preview.cells.subviews.compactMap { $0 as? NSButton }.contains {
        $0.accessibilityLabel()?.contains(problem) == true
      })
  }

  @Test func unsupportedRangePatternOutranksFailedRangeMembers() async throws {
    let (editor, table, controller) = try await ExpandedTableTests().makeEditor()
    try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "=IF(A2 > 1000, 1, 0)")
    try editor.setTableCell(table.id, at: .init(row: 2, column: 1), source: "=SUM(B2:B3, A2:A3)")
    await editor.scheduler?.waitUntilIdle()
    let problem = try #require(controller.cellProblem(row: 2, column: 1))
    #expect(problem.contains("one range per aggregate"))
    #expect(controller.exportGrid(mode: .values).rows[2][1] == problem)
    controller.select(.init(row: 2, column: 1))
    controller.beginEditing()
    let field = try #require(controller.formula.currentEditor() as? NSTextView)
    #expect((field.string as NSString).substring(with: field.selectedRange()) == "B2:B3")
  }

}
