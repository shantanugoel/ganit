import AppKit
import Foundation
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

/// M3 task 4: structural table edits pass through the document's one source
/// pipeline. Each is one Undo step that restores exact bytes and the
/// selection, rewrites moved line references with it, and is saved and
/// evaluated as typing is. Prose failures caused by a table cell lead to that
/// cell's source.
@MainActor
@Suite(.serialized)
struct TableSourceCoordinatorTests {
  /// `Items`: Qty literals and an Amount column rule reading `rate`.
  static func items() -> TableModel {
    var table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: 2)
    table.columns[1].rule = "=[@Qty] * rate"
    for (row, qty) in ["2", "4"].enumerated() {
      table.cells.append(TableCell(row: table.rows[row], column: table.columns[0].id, source: qty))
    }
    return table
  }

  static func block(_ table: TableModel) throws -> String {
    try TableSourceDocument.canonicalBlock(for: table)
  }

  // MARK: Undo, redo and the shared pipeline

  @Test
  func aStructuralEditIsOneUndoStepRestoringExactBytes() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table)) + "Items!B3\nsum(Items[Amount])\n@1 * 2\n"
    let (editor, textView) = try await makeEditor(original)
    var saved = 0
    editor.sourceDidChange = { saved += 1 }
    #expect(answers(editor).suffix(3) == ["12", "18", "6"])

    try editor.insertTableRows(table.id, at: 0)
    let inserted = textView.string
    #expect(inserted != original)
    #expect(editor.sheet.text == inserted)
    #expect(saved > 0)
    #expect(editor.documentUndoManager.undoActionName == "Insert Rows")
    // The prose operand follows its row; the new row inherits the rule.
    #expect(inserted.contains("Items!B4\n"))
    await editor.scheduler?.waitUntilIdle()
    // The inserted row inherits the rule, which has no Qty to read yet.
    #expect(answers(editor).suffix(3) == ["12", "failure", "6"])
    let model = try #require(editor.latestEvaluation?.tableResult(table.id))
    #expect(model.rows.count == 3)

    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(original.utf8))
    #expect(Array(editor.sheet.text.utf8) == Array(original.utf8))
    #expect(!editor.documentUndoManager.canUndo)
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableResult(table.id)?.rows == table.rows)
    #expect(answers(editor).suffix(3) == ["12", "18", "6"])

    editor.documentUndoManager.redo()
    #expect(Array(textView.string.utf8) == Array(inserted.utf8))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableResult(table.id)?.rows == model.rows)
    #expect(answers(editor).suffix(3) == ["12", "failure", "6"])
  }

  @Test
  func cellEditsRecalculateAndUpdateProseBelow() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table)) + "total = sum(Items[Amount])\n"
    let (editor, _) = try await makeEditor(original)
    #expect(answers(editor).last == "18")
    try editor.setTableCell(table.id, at: TableCellPosition(row: 1, column: 0), source: "10")
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).last == "36")
    try editor.appendTableRows(table.id)
    try editor.setTableCell(table.id, at: TableCellPosition(row: 2, column: 0), source: "1")
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).last == "39")
    try editor.setTableColumnRule(table.id, column: table.columns[1].id, formula: "=[@Qty] * @1")
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).last == "39")
    editor.documentUndoManager.undo()
    editor.documentUndoManager.undo()
    editor.documentUndoManager.undo()
    editor.documentUndoManager.undo()
    #expect(Array(editor.textView.string.utf8) == Array(original.utf8))
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).last == "18")
  }

  @Test
  func insertingATableRenumbersProseInTheSameUndoStep() async throws {
    let original = "10\n20\n@2 + @1\n"
    let (editor, textView) = try await makeEditor(original)
    let id = try #require(
      try editor.createTable(
        named: "Items", headers: [("Qty", .value)], rowCount: 1, atUTF8: 3))
    let lines = (TableSourceDocument.blockLineRanges(in: editor.sheet).first?.count ?? 0)
    #expect(lines == 3)
    #expect(textView.string.hasSuffix("20\n@5 + @1\n"))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableResult(id)?.name == "Items")
    #expect(answers(editor).suffix(1) == ["30"])
    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(original.utf8))
    editor.documentUndoManager.redo()
    #expect(textView.string.hasSuffix("20\n@5 + @1\n"))
  }

  @Test
  func typingAboveATableMovesItsFormulaLineReadsInTheSameUndoStep() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table)) + "Items!B2\n"
    let (editor, textView) = try await makeEditor(original)
    try editor.setTableCell(table.id, at: TableCellPosition(row: 0, column: 1), source: "=@1 * 5")
    let withFormula = textView.string
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).last == "15")

    edit(editor, NSRange(location: 0, length: 0), "x = 1\n")
    #expect(textView.string.contains("=@2 * 5"))
    #expect(!textView.string.contains("=@1 * 5"))
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.tableDiagnostics.isEmpty == true)
    #expect(answers(editor).last == "15")
    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(withFormula.utf8))
    editor.documentUndoManager.redo()
    #expect(textView.string.contains("=@2 * 5"))
    #expect(textView.string.hasPrefix("x = 1\nrate = 3\n"))
  }

  @Test
  func undoAndRedoRestoreTheSelectionAroundAnEdit() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table)) + "Items!B2 + 1\n"
    let (editor, textView) = try await makeEditor(original)
    let prose = (original as NSString).range(of: "Items!B2 + 1")
    textView.setSelectedRange(NSRange(location: prose.location + 9, length: 3))
    try editor.insertTableColumn(table.id, at: 2, header: "Note", policy: .text)
    let moved = (textView.string as NSString).range(of: "Items!B2 + 1")
    let after = textView.selectedRange()
    #expect(after == NSRange(location: moved.location + 9, length: 3))
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.documentUndoManager.undo()
    #expect(textView.selectedRange() == NSRange(location: prose.location + 9, length: 3))
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.documentUndoManager.redo()
    #expect(textView.selectedRange() == after)
  }

  @Test
  func everyStructuralEntryPointIsOneUndoableEdit() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table)) + "Items!B2\n"
    let (editor, textView) = try await makeEditor(original)
    let amount = table.columns[1].id
    let operations: [(String, () throws -> Void)] = [
      ("Insert Rows", { try editor.insertTableRows(table.id, at: 1, count: 2) }),
      ("Insert Rows", { try editor.appendTableRows(table.id) }),
      ("Delete Rows", { try editor.deleteTableRows(table.id, in: 0..<1) }),
      ("Insert Column", { try editor.insertTableColumn(table.id, at: 0, header: "Code") }),
      ("Delete Columns", { try editor.deleteTableColumns(table.id, in: 0..<1) }),
      ("Rename Table", { try editor.renameTable(table.id, to: "Goods") }),
      ("Rename Column", { try editor.renameTableColumn(table.id, column: amount, to: "Cost") }),
      (
        "Edit Cell",
        { try editor.setTableCell(table.id, at: .init(row: 0, column: 1), source: "7") }
      ),
      (
        "Change Column Formula",
        { try editor.setTableColumnRule(table.id, column: amount, formula: "=[@Qty] * 2") }
      ),
      ("Change Total", { try editor.setTableColumnTotal(table.id, column: amount, total: .sum) }),
      (
        "Change Column Input",
        {
          try editor.setTableColumnInput(
            table.id, column: table.columns[0].id, policy: .value, unit: "kg")
        }
      ),
      (
        "Paste",
        {
          try editor.copyTableCell(
            table.id, from: .init(row: 0, column: 0), to: .init(row: 1, column: 0))
        }
      ),
      (
        "Paste",
        {
          let clipboard = try TableSourceDocument(editor.sheet).clipboard(
            table: table.id, rectangle: .init(rows: 0..<1, columns: 0..<1))
          try editor.pasteTableCells(clipboard, into: table.id, at: .init(row: 1, column: 0))
        }
      ),
      (
        "Paste",
        {
          try editor.pasteTablePlainText(
            "9\t=[@Qty]", into: table.id, at: .init(row: 0, column: 0), formulas: true)
        }
      ),
      (
        "Fill",
        {
          try editor.fillTableCells(
            table.id, from: .init(row: 0, column: 0), into: .init(rows: 0..<2, columns: 0..<1))
        }
      ),
      (
        "Move Cells",
        {
          try editor.moveTableCells(
            table.id, rectangle: .init(rows: 0..<1, columns: 0..<1), to: .init(row: 1, column: 0))
        }
      ),
      (
        "Duplicate Table",
        {
          _ = try editor.duplicateTable(
            table.id, named: "Copy", atUTF8: (original as NSString).length)
        }
      ),
    ]
    for (name, operation) in operations {
      try operation()
      let changed = textView.string
      #expect(changed != original, "\(name)")
      #expect(editor.documentUndoManager.undoActionName == name)
      await editor.scheduler?.waitUntilIdle()
      #expect(editor.latestEvaluation?.tableDiagnostics.isEmpty == true, "\(name)")
      editor.documentUndoManager.undo()
      #expect(Array(textView.string.utf8) == Array(original.utf8), "\(name)")
      editor.documentUndoManager.redo()
      #expect(Array(textView.string.utf8) == Array(changed.utf8), "\(name)")
      editor.documentUndoManager.undo()
      #expect(!editor.documentUndoManager.canUndo, "\(name)")
    }
  }

  @Test
  func refusedAndStaleEditsChangeNothing() async throws {
    let table = Self.items()
    let original = "rate = 3\n" + (try Self.block(table))
    let (editor, textView) = try await makeEditor(original)
    #expect(throws: TableTransformError.invalidPosition) {
      try editor.deleteTableRows(table.id, in: 0..<9)
    }
    let edit = try TableSourceDocument(editor.sheet).renameTable(table.id, to: "Goods")
    textView.isEditable = false
    #expect(throws: SheetSourceCoordinator.Failure.notEditable) {
      try editor.sourceCoordinator.apply(edit.patches, actionName: "Rename Table")
    }
    textView.isEditable = true
    self.edit(editor, NSRange(location: 0, length: 0), "x\n")
    #expect(throws: SheetSourceCoordinator.Failure.staleEdit) {
      try editor.sourceCoordinator.apply(edit.patches, actionName: "Rename Table")
    }
    #expect(textView.string == "x\n" + original)
    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(original.utf8))
    #expect(!editor.documentUndoManager.canUndo)
  }

  // MARK: Failure navigation

  @Test
  func aTableCausedFailureLeadsToTheOriginalCell() async throws {
    var table = TableModel.creating(
      name: "Bad", headers: [("A", .value), ("B", .value)], rowCount: 1)
    table.cells = [
      TableCell(row: table.rows[0], column: table.columns[0].id, source: "=1 +"),
      TableCell(row: table.rows[0], column: table.columns[1].id, source: "=A2 * 2"),
    ]
    let source = "1\n" + (try Self.block(table)) + "x = Bad!B2\nx + 1\n"
    let (editor, textView) = try await makeEditor(source)
    for line in [editor.sheet.lines.count - 3, editor.sheet.lines.count - 2] {
      let id = editor.sheet.lines[line].id
      let rows = textView.interpretation(id)
      let origin = try #require(rows.first { $0.sourceRange != nil })
      #expect(origin.label == "Fix first" && origin.value == "Bad!A2")
      let card = InterpretationViewController(
        details: rows, fullPrecision: nil, availableSize: NSSize(width: 800, height: 600),
        pasteboard: .general, onSelectLine: { textView.selectErrorOrigin(line: $0) },
        onSelectRange: { textView.selectErrorOrigin(range: $0) })
      let grid = try #require(
        (card.view.subviews.first as? NSScrollView)?.documentView as? NSGridView)
      let button = try #require(
        (0..<grid.numberOfRows).compactMap {
          grid.cell(atColumnIndex: 1, rowIndex: $0).contentView as? NSButton
        }.first { $0.title == "Bad!A2" })
      textView.setSelectedRange(NSRange(location: 0, length: 0))
      button.performClick(nil)
      #expect(
        (textView.string as NSString).substring(with: textView.selectedRange()) == "\"=1 +\"")
    }
  }

  // MARK: Scheduler

  @Test
  func onlyTheNewestTableGenerationCommitsWithOneContext() async throws {
    let table = Self.items()
    var clock = TableModel.creating(name: "Clock", headers: [("Now", .value)], rowCount: 1)
    clock.cells = [TableCell(row: clock.rows[0], column: clock.columns[0].id, source: "=now")]
    let recorder = Recorder()
    let scheduler = SheetEvaluationScheduler(context: try testContext()) {
      _, evaluation, interval in
      interval.cancel()
      recorder.commits.append(evaluation)
    }
    func sheet(_ rate: Int) throws -> SheetSource {
      SheetSource(
        "rate = \(rate)\n" + (try Self.block(table)) + (try Self.block(clock))
          + "now\nsum(Items[Amount])\n")
    }
    // The first generation finishes while the main actor is busy, so its
    // commit waits until newer generations have superseded it.
    scheduler.schedule(try sheet(1))
    await Task.yield()
    usleep(300_000)
    scheduler.schedule(try sheet(2))
    scheduler.schedule(try sheet(3))
    await scheduler.waitUntilIdle()
    #expect(recorder.commits.count == 1)
    let evaluation = try #require(recorder.commits.last)
    guard case .value(.number(.integer(let total)))? = evaluation.lines.dropLast().last?.result
    else {
      Issue.record("The total has no value")
      return
    }
    #expect(total.canonicalDigits == "18")
    // Every table and line of a generation read one clock.
    let snapshots = evaluation.tables.compactMap(\.calculation)
    #expect(snapshots.count == 2)
    #expect(Set(snapshots.map(\.context.now)).count == 1)
    guard case .value(.instant(let now))? = evaluation.lines.dropLast(2).last?.result,
      case .value(.instant(let cell))? = evaluation.tableResult(clock.id)?.value(
        row: clock.rows[0], column: clock.columns[0].id)
    else {
      Issue.record("The clock was not read")
      return
    }
    // A clock reading is reused within the second it stays correct for, as
    // a line's is, so one generation never shows two different seconds.
    #expect(cell.date == snapshots[1].context.now)
    #expect(floor(now.date.timeIntervalSince1970) == floor(cell.date.timeIntervalSince1970))
    #expect(evaluation.nextRecalculation == snapshots[1].nextRecalculation)
    #expect(scheduler.recalculation != nil)
    scheduler.cancel()
  }

  @Test
  func aClockReadingTableArmsAndRunsARecalculation() async throws {
    var table = TableModel.creating(name: "Clock", headers: [("Now", .value)], rowCount: 1)
    table.cells = [TableCell(row: table.rows[0], column: table.columns[0].id, source: "=now")]
    let (editor, _) = try await makeEditor(try Self.block(table))
    #expect(editor.scheduler?.recalculation != nil)
    let first = try #require(editor.latestEvaluation)
    let value = first.tableResult(table.id)?.value(row: table.rows[0], column: table.columns[0].id)
    #expect(value != nil)
    #expect(first.tableResult(table.id)?.nextRecalculation == first.nextRecalculation)
    // The recalculation fires at the next second, however busy the run is.
    let deadline = ContinuousClock.now + .seconds(20)
    while editor.latestEvaluation?.generation == first.generation, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
      await editor.scheduler?.waitUntilIdle()
    }
    let second = try #require(editor.latestEvaluation)
    #expect(second.generation > first.generation)
    #expect(
      second.tableResult(table.id)?.value(row: table.rows[0], column: table.columns[0].id)
        != value)
    editor.stopCalculation(nil)
    #expect(editor.scheduler?.recalculation == nil)
  }

  // MARK: Helpers

  private func answers(_ editor: SheetEditorViewController) -> [String?] {
    (editor.latestEvaluation?.lines ?? []).dropLast().map { line in
      switch line.result {
      case .value(.number(.integer(let integer))): return integer.canonicalDigits
      case .value: return "value"
      case .syntaxFailure, .evaluationFailure: return "failure"
      case nil: return nil
      }
    }
  }

  /// One undoable typed edit.
  private func edit(_ editor: SheetEditorViewController, _ range: NSRange, _ replacement: String) {
    editor.textView.breakUndoCoalescing()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(replacement, replacementRange: range)
    editor.documentUndoManager.endUndoGrouping()
  }

  private static var windows: [NSWindow] = []

  private func makeEditor(_ text: String) async throws -> (SheetEditorViewController, SheetTextView)
  {
    let editor = SheetEditorViewController(text: text, context: try testContext())
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return (editor, try #require(editor.textView as? SheetTextView))
  }

  private func testContext() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US",
      lexingConfiguration: .englishUnitedStates,
      angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0),
      calendar: Calendar(identifier: .gregorian),
      timeZone: try #require(TimeZone(identifier: "UTC"))
    )
  }
}

@MainActor
private final class Recorder {
  var commits: [SheetEvaluation] = []
}
