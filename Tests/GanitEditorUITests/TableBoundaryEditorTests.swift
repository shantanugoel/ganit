import AppKit
import Foundation
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

/// M3 task 5 in the editor: no table problem is sent to the assistant, the
/// definitions sheet and Quick Ganit say why their tables are not
/// calculated, and deleting a table, by command or by deleting its text,
/// breaks its readers in the same Undo step.
@MainActor
@Suite(.serialized)
struct TableBoundaryEditorTests {
  static func items() -> TableModel {
    var table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: 3)
    for (row, source) in ["2", "=nothing + 1", "=ask_assistant(10 kg of water in ml)"]
      .enumerated()
    {
      table.cells.append(
        TableCell(row: table.rows[row], column: table.columns[0].id, source: source))
    }
    return table
  }

  // MARK: Assistant

  /// Table block lines, failing table cells, and prose that fails reading a
  /// table never reach the assistant; an ordinary line Ganit cannot work out
  /// still does.
  @Test
  func tableProblemsNeverAskTheAssistant() async throws {
    let source =
      (try TableSourceDocument.canonicalBlock(for: Self.items()))
      + "Items!A3\nItems[Missing]\nNope[Amount]\nsum(Items!A2:A4)\n@2\n10 kg of water in ml\n"
    let (editor, _) = try await makeEditor(source)
    let asked = Asked()
    editor.assistantPause = .milliseconds(10)
    editor.askAssistant = { line in
      await asked.record(line)
      return "42"
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while await asked.lines.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await asked.lines == ["10 kg of water in ml"])
    let lines = try #require(editor.latestEvaluation?.lines)
    #expect(lines.allSatisfy { $0.assistantPrompts.isEmpty })
    // The table failures keep their own explanations.
    for index in 3...7 {
      guard case .evaluationFailure(let error) = lines[index].result else {
        Issue.record("line \(index + 1) fails")
        continue
      }
      #expect(error.code == .tableReference)
    }
    // Ask Assistant has nothing to send for a table problem either.
    editor.textView.setSelectedRange(
      NSRange(location: (source as NSString).range(of: "Nope").location, length: 0))
    #expect(!editor.canAskAssistant())
  }

  /// Off the workspace, the opener explains; nothing is asked about it.
  @Test
  func definitionsAndQuickGanitExplainTheirTables() async throws {
    let table = Self.items()
    let source =
      (try TableSourceDocument.canonicalBlock(for: table)) + "total = sum(Items[Qty])\nrate = 2\n"
    for (surface, key) in [
      (SheetSurface.definitions, "definitions"), (SheetSurface.quickGanit, "quickGanit"),
    ] {
      let (editor, _) = try await makeEditor(source, surface: surface)
      var shared: [SheetDefinitions] = []
      editor.definitionsDidChange = { shared.append($0) }
      let asked = Asked()
      editor.assistantPause = .milliseconds(10)
      editor.askAssistant = { line in
        await asked.record(line)
        return "42"
      }
      editor.recalculate(nil)
      await editor.scheduler?.waitUntilIdle()
      let lines = await editor.exportedLines()
      let message = DiagnosticFormatter(context: try testContext()).format(
        EngineError(
          code: .tableReference,
          context: .tableReference(surface == .definitions ? .definitions : .quickGanit))
      ).message
      #expect(lines[0].answer == message && lines[0].status == .failure, "\(key)")
      #expect(lines[1].answer == nil && lines[2].answer == nil)
      #expect(lines[3].answer == message)
      #expect(lines[4].answer == "2")
      #expect(editor.latestEvaluation?.definitions.variables.keys.sorted() == ["rate"])
      try await Task.sleep(for: .milliseconds(200))
      #expect(await asked.lines.isEmpty, "\(key)")
    }
  }

  // MARK: Deleting a table

  /// `base = 10`, Rates, `k = 4`, Items reading Rates and line 5, prose
  /// reading Rates and line 5.
  static func readerSheet() throws -> (String, TableID, TableID) {
    var rates = TableModel.creating(name: "Rates", headers: [("Rate", .value)], rowCount: 2)
    rates.cells = [
      TableCell(row: rates.rows[0], column: rates.columns[0].id, source: "2"),
      TableCell(row: rates.rows[1], column: rates.columns[0].id, source: "3"),
    ]
    var source = "base = 10\n" + (try TableSourceDocument.canonicalBlock(for: rates)) + "k = 4\n"
    let items = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Total", .value)], rowCount: 1)
    source += try TableSourceDocument.canonicalBlock(for: items)
    source = try TableSourceDocument(source).setCell(
      table: items.id, at: .init(row: 0, column: 1), source: "=sum(Rates[Rate]) + @5"
    ).applying(to: source)
    source = try TableSourceDocument(source).setCell(
      table: items.id, at: .init(row: 0, column: 0), source: "=Rates!A2"
    ).applying(to: source)
    source += "x = Rates!A2 + 1\nw = @5 + 1\nItems!B2\n"
    #expect(TableSourceDocument(source).diagnostics.isEmpty)
    return (source, rates.id, items.id)
  }

  @Test
  func deleteTableIsOneUndoStepThatBreaksReaders() async throws {
    let (original, rates, items) = try Self.readerSheet()
    let (editor, textView) = try await makeEditor(original)
    #expect(answers(editor).suffix(3) == ["3", "5", "9"])

    try editor.deleteTable(rates)
    let deleted = textView.string
    #expect(editor.documentUndoManager.undoActionName == "Delete Table")
    #expect(!deleted.contains("\"n\":\"Rates\""))
    #expect(deleted.contains("x = #REF!{\(rates.string)/"))
    #expect(deleted.contains("w = @2 + 1\n"))
    #expect(deleted.contains("=sum(#REF!{range:") && deleted.contains(") + @2"))
    #expect(TableSourceDocument(deleted).diagnostics.isEmpty)
    await editor.scheduler?.waitUntilIdle()
    // The reader is calculated with a failing cell rather than quarantined.
    let snapshot = try #require(editor.latestEvaluation?.tableResult(items))
    #expect(snapshot.diagnostics.isEmpty && snapshot.isCalculated)
    #expect(answers(editor).suffix(3) == ["failure", "5", "failure"])

    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(original.utf8))
    #expect(!editor.documentUndoManager.canUndo)
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).suffix(3) == ["3", "5", "9"])

    editor.documentUndoManager.redo()
    #expect(Array(textView.string.utf8) == Array(deleted.utf8))
    // Reloading the saved text reads the same tables and answers.
    let (reloaded, _) = try await makeEditor(deleted)
    #expect(
      reloaded.latestEvaluation?.tableResults.map(\.id)
        == editor.latestEvaluation?.tableResults.map(\.id))
    #expect(answers(reloaded).suffix(3) == ["failure", "5", "failure"])

    // A new table with the deleted one's name revives no reference.
    let recreated = try #require(
      try reloaded.createTable(
        named: "Rates", headers: [("Rate", .value)], rowCount: 1, atUTF8: 0))
    #expect(recreated != rates)
    await reloaded.scheduler?.waitUntilIdle()
    #expect(answers(reloaded).suffix(3) == ["failure", "5", "failure"])
  }

  /// Selecting a table's lines and deleting them is the same edit as Delete
  /// Table, in one Undo step with the user's deletion.
  @Test
  func deletingABlockByTypingBreaksReadersInTheSameUndoStep() async throws {
    let (original, rates, _) = try Self.readerSheet()
    let (editor, textView) = try await makeEditor(original)
    let block = TableSourceDocument(original).blocks[0]
    let start = String(decoding: original.utf8.prefix(block.utf8Range.lowerBound), as: UTF8.self)
      .utf16.count
    edit(editor, NSRange(location: start, length: block.rawSource.utf16.count), "")
    let typed = textView.string
    #expect(typed.contains("x = #REF!{\(rates.string)/"))
    #expect(typed.contains("w = @2 + 1\n"))
    #expect(TableSourceDocument(typed).diagnostics.isEmpty)
    await editor.scheduler?.waitUntilIdle()
    #expect(answers(editor).suffix(3) == ["failure", "5", "failure"])

    editor.documentUndoManager.undo()
    #expect(Array(textView.string.utf8) == Array(original.utf8))
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    #expect(Array(textView.string.utf8) == Array(typed.utf8))
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

  private func edit(_ editor: SheetEditorViewController, _ range: NSRange, _ replacement: String) {
    editor.textView.breakUndoCoalescing()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(replacement, replacementRange: range)
    editor.documentUndoManager.endUndoGrouping()
  }

  private static var windows: [NSWindow] = []

  private func makeEditor(_ text: String, surface: SheetSurface = .workspace) async throws
    -> (SheetEditorViewController, SheetTextView)
  {
    let editor = SheetEditorViewController(text: text, context: try testContext(), surface: surface)
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

private actor Asked {
  private(set) var lines: [String] = []

  func record(_ line: String) {
    lines.append(line)
  }
}
