import AppKit
import Foundation
import GanitDiagnostics
import GanitFormatting
import Testing

@testable import GanitEditorUI
@testable import GanitEngine

/// Table blocks in the editor, valid or not, keep exactly the bytes the
/// reader gave them: ordinary edits, Undo and Redo never reformat or repair
/// a block, editor conveniences never rewrite one, block lines show no
/// answers in either sheet mode, and the newest evaluation never shows a
/// block's previous valid table.
@MainActor
@Suite(.serialized)
struct TableBlockRetentionTests {
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "GanitEngineTests/Fixtures/TableBlocks", directoryHint: .isDirectory)

  static func fixture(_ name: String) throws -> String {
    try #require(
      String(data: try Data(contentsOf: fixtures.appending(path: name)), encoding: .utf8))
  }

  /// Each fixture's diagnostics as stored.
  static let diagnostics: [String: [TableSourceDiagnostic.Code]] = [
    "malformed-json.txt": [.malformed],
    "malformed-opener.txt": [.malformed, .malformed, .malformed],
    "unsupported-version.txt": [.unsupportedVersion],
    "unterminated.txt": [.unterminated],
    "duplicate-id.txt": [.duplicateIdentity, .duplicateIdentity],
    "stale-fingerprint.txt": [.staleBinding],
    "orphan-target.txt": [.orphanTarget],
    "line-endings-cr.txt": [],
  ]

  @Test(
    arguments: [
      "malformed-json.txt", "malformed-opener.txt", "unsupported-version.txt", "unterminated.txt",
      "duplicate-id.txt", "stale-fingerprint.txt", "orphan-target.txt", "line-endings-cr.txt",
    ], [false, true])
  func blocksKeepTheirBytesThroughEditsUndoAndRedo(fixture: String, markdown: Bool) async throws {
    let original = try Self.fixture(fixture)
    let (editor, textView) = try await makeEditor(original, markdown: markdown)
    var expected = original
    try await expectQuarantined(editor, textView, expected, codes: Self.diagnostics[fixture])
    var steps = [expected]

    // A line inserted above keeps every block, and it has an answer of its own.
    edit(editor, &expected, NSRange(location: 0, length: 0), "x = 1 =>\n")
    try await expectQuarantined(editor, textView, expected, codes: Self.diagnostics[fixture])
    #expect(textView.answer(editor.sheet.lines[0].id) != nil)
    steps.append(expected)

    // Typing inside the first block changes only the typed bytes.
    let first = try #require(TableSourceDocument.blockLineRanges(in: editor.sheet).first)
    let payload = utf16Start(ofLine: first.lowerBound + 1, in: expected)
    edit(editor, &expected, NSRange(location: payload, length: 0), "Z")
    try await expectQuarantined(editor, textView, expected)
    #expect(editor.latestEvaluation?.tables.first?.diagnostics.isEmpty == false)
    steps.append(expected)

    // Deleting a closer extends the block to the next closer, or quarantines
    // it through the end of the sheet when there is none.
    let lines = editor.sheet.lines
    if lines[first.upperBound - 1].text == "@end-ganit-table" {
      let later = lines[first.upperBound...].firstIndex { $0.text == "@end-ganit-table" }
      let start = utf16Start(ofLine: first.upperBound - 1, in: expected)
      edit(editor, &expected, NSRange(location: start, length: 16), "")
      try await expectQuarantined(editor, textView, expected)
      let merged = try #require(TableSourceDocument.blockLineRanges(in: editor.sheet).first)
      #expect(merged == first.lowerBound..<(later.map { $0 + 1 } ?? lines.count))
      let codes = editor.latestEvaluation?.tables.first?.diagnostics.map(\.code)
      #expect(later != nil ? codes?.isEmpty == false : codes == [.unterminated])
      steps.append(expected)
    }

    // Removing the line above moves the blocks back up.
    edit(editor, &expected, NSRange(location: 0, length: 9), "")
    try await expectQuarantined(editor, textView, expected)
    steps.append(expected)

    for step in steps.reversed().dropFirst() {
      editor.documentUndoManager.undo()
      try await expectQuarantined(editor, textView, step)
    }
    try await expectQuarantined(editor, textView, original, codes: Self.diagnostics[fixture])
    for step in steps.dropFirst() {
      editor.documentUndoManager.redo()
      try await expectQuarantined(editor, textView, step)
    }
  }

  /// Completion, number stepping, answer arrows, inserted lines and
  /// references, comment toggles and reinterpretation leave block source
  /// alone. Only what the reader types, pastes or deletes changes it.
  @Test
  func editorConveniencesNeverRewriteBlockSource() async throws {
    let block = try Self.fixture("line-endings-lf.txt")
    let source = "rate = 2\n" + block + "@ganit-table 7\n5 m\n@end-ganit-table\n5 m"
    let (editor, textView) = try await makeEditor(source, markdown: false, groupsUndoByEvent: true)
    textView.completesWhileTyping = true
    let text = { textView.string as NSString }
    func location(of needle: String) -> Int { text().range(of: needle).location }

    // A reference query inside a block offers nothing, so Return is a newline.
    let tripEnd = location(of: "\"Trip\",") + 7
    textView.setSelectedRange(NSRange(location: tripEnd, length: 0))
    textView.insertText(" @", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions.isEmpty)
    textView.insertText(" ra", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions.isEmpty)
    textView.insertNewline(nil)
    var expected = (source as NSString).replacingCharacters(
      in: NSRange(location: tripEnd, length: 0), with: " @ ra\n")
    #expect(textView.string.utf8.elementsEqual(expected.utf8))
    // Prose still completes.
    textView.setSelectedRange(NSRange(location: text().length, length: 0))
    textView.insertText("\nra", replacementRange: textView.selectedRange())
    #expect(textView.offeredCompletions.first == "rate")
    textView.complete(nil)
    textView.insertText("", replacementRange: NSRange(location: text().length - 3, length: 3))
    #expect(textView.string.utf8.elementsEqual(expected.utf8))
    await editor.scheduler?.waitUntilIdle()

    // Point commands inside a block beep instead of editing it.
    let rows = location(of: "\"r\": [4") + 7
    textView.setSelectedRange(NSRange(location: rows, length: 0))
    textView.stepNumberUp(nil)
    textView.stepNumberDown(nil)
    textView.insertAnswerArrow(nil)
    textView.insertDivider(nil)
    textView.insertSubtotal(nil)
    textView.insertReference(nil)
    #expect(textView.string.utf8.elementsEqual(expected.utf8))
    #expect(textView.interpretationMenu(atUTF16: location(of: "5 m\n@end") + 2) == nil)
    #expect(textView.interpretationMenu(atUTF16: text().length - 1) != nil)
    // The same commands work in prose.
    textView.setSelectedRange(NSRange(location: 7, length: 0))
    textView.stepNumberUp(nil)
    #expect(textView.string.hasPrefix("rate = 3\n"))
    textView.stepNumberDown(nil)
    #expect(textView.string.utf8.elementsEqual(expected.utf8))

    try await expectQuarantined(editor, textView, expected)
    // Toggling comments over prose and blocks comments only the prose.
    textView.setSelectedRange(NSRange(location: 0, length: text().length))
    textView.toggleComment(nil)
    let commented = expected.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
      .map { index, line -> String in
        let isBlock = TableSourceDocument.blockLineRanges(in: SheetSource(expected))
          .contains { $0.contains(index) }
        return isBlock || line.isEmpty ? String(line) : "// " + line
      }.joined(separator: "\n")
    #expect(textView.string.utf8.elementsEqual(commented.utf8))
    textView.toggleComment(nil)
    #expect(textView.string.utf8.elementsEqual(expected.utf8))
    // A selection of block lines alone is left as it is.
    let blockOnly = NSRange(location: location(of: "@ganit-table 7"), length: 20)
    textView.setSelectedRange(blockOnly)
    textView.toggleHeading(nil)
    #expect(textView.string.utf8.elementsEqual(expected.utf8))

    try await expectQuarantined(editor, textView, expected)
    // Pasting into a block keeps the pasted bytes exactly.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GanitTableRetention-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("\"q\" -- 'x'\r\n...", forType: .string)
    let at = location(of: "\"Trip\"")
    textView.setSelectedRange(NSRange(location: at, length: 0))
    #expect(textView.readSelection(from: pasteboard, type: .string))
    expected = (expected as NSString).replacingCharacters(
      in: NSRange(location: at, length: 0), with: "\"q\" -- 'x'\r\n...")
    #expect(textView.string.utf8.elementsEqual(expected.utf8))
    #expect(editor.sheet.text.utf8.elementsEqual(expected.utf8))
    try await expectQuarantined(editor, textView, expected)
  }

  /// A blank block line has a zero-length comment run, and TextKit 2 throws
  /// on a rendering attribute for an empty text range: a sheet with a blank
  /// line inside a block crashed when that line was decorated, as on first
  /// display or after Return inside a block.
  @Test(arguments: [false, true])
  func blankBlockLinesDecorateWithoutCrashing(markdown: Bool) async throws {
    let source =
      "rate = 2 =>\n@ganit-table 1\n{\n}\n@end-ganit-table\n@ganit-table 9\n\n@end-ganit-table\n"
      + "rate * 2 =>"
    let (editor, textView) = try await makeEditor(
      source, markdown: markdown, groupsUndoByEvent: true)
    try await expectQuarantined(editor, textView, source)
    let brace = (source as NSString).range(of: "{").upperBound
    textView.setSelectedRange(NSRange(location: brace, length: 0))
    textView.insertNewline(nil)
    let expected = (source as NSString).replacingCharacters(
      in: NSRange(location: brace, length: 0), with: "\n")
    try await expectQuarantined(editor, textView, expected)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    try await expectQuarantined(editor, textView, expected)
    textView.setSelectedRange(NSRange(location: 0, length: (expected as NSString).length))
    textView.toggleComment(nil)
    await editor.scheduler?.waitUntilIdle()
    textView.toggleComment(nil)
    try await expectQuarantined(editor, textView, expected)
    #expect(textView.answer(editor.sheet.lines[0].id) != nil)
    #expect(textView.answer(try #require(editor.sheet.lines.last).id) != nil)
  }

  /// Commands that would write into a block are disabled there, including
  /// Insert Reference for a selection that touches a block line anywhere.
  @Test
  func commandsThatWouldWriteIntoABlockAreDisabled() async throws {
    let source = "10 =>\n20\n@ganit-table 9\nabc\n@end-ganit-table\nx"
    let (_, textView) = try await makeEditor(source, markdown: false, groupsUndoByEvent: true)
    func enabled(_ action: Selector) -> Bool {
      textView.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    let reference = #selector(SheetTextView.insertReference(_:))
    let lineCommands = [
      #selector(SheetTextView.insertSubtotal(_:)), #selector(SheetTextView.insertDivider(_:)),
      #selector(SheetTextView.insertAnswerArrow(_:)),
    ]
    let toggles = [
      #selector(SheetTextView.toggleComment(_:)), #selector(SheetTextView.toggleHeading(_:)),
    ]
    let text = source as NSString
    let twenty = text.range(of: "20").location

    // A selection from prose into a block, or ending at an opener's start,
    // would overwrite or join block source.
    for end in [text.range(of: "abc").location + 1, text.range(of: "@ganit").location] {
      textView.setSelectedRange(NSRange(location: twenty, length: end - twenty))
      #expect(!enabled(reference))
      textView.insertReference(nil)
      #expect(textView.string == source)
      #expect(toggles.allSatisfy(enabled))
    }

    // Inside a block, or on its closer, nothing writes there.
    for caret in [text.range(of: "abc").location + 1, text.range(of: "@end").location + 3] {
      textView.setSelectedRange(NSRange(location: caret, length: 0))
      #expect(!enabled(reference))
      #expect(!lineCommands.contains(where: enabled))
      #expect(!toggles.contains(where: enabled))
      for command in lineCommands + [reference] + toggles {
        textView.perform(command, with: nil)
      }
      #expect(textView.string == source)
    }

    // In prose the same commands are enabled and work.
    textView.setSelectedRange(NSRange(location: text.length, length: 0))
    #expect(lineCommands.allSatisfy(enabled) && toggles.allSatisfy(enabled))
    textView.setSelectedRange(NSRange(location: twenty, length: 2))
    #expect(enabled(reference))
    textView.insertReference(nil)
    #expect(
      textView.string
        == text.replacingCharacters(in: NSRange(location: twenty, length: 2), with: "line 1"))
  }

  /// The editor's evaluation commit never shows a block's previous valid
  /// table once an edit makes it invalid, and Undo brings the table back.
  @Test
  func theNewestEvaluationNeverShowsAPreviousValidTable() async throws {
    let original = try Self.fixture("line-endings-lf.txt")
    let (editor, textView) = try await makeEditor(original, markdown: false)
    try await expectQuarantined(editor, textView, original, codes: [])
    let table = try #require(editor.latestEvaluation?.tables.first?.projection)
    let source = original as NSString
    let stale = source.range(of: "/ 2\"}")
    let lines = SheetSource(original).lines
    let block = try #require(TableSourceDocument.blockLineRanges(in: SheetSource(original)).first)
    let copy = lines[block].map { $0.text + ($0.terminator?.rawValue ?? "") }.joined()
      .replacingOccurrences(of: "30000000-", with: "31000000-")
    #expect(original.hasSuffix("\n") && copy.hasSuffix("\n"))
    let cases: [(NSRange, String, [[TableSourceDiagnostic.Code]])] = [
      (NSRange(location: utf16Start(ofLine: 3, in: original), length: 0), "x", [[.malformed]]),
      (NSRange(location: stale.location + 2, length: 1), "3", [[.staleBinding]]),
      (NSRange(location: source.length, length: 0), copy, [[.duplicateName], [.duplicateName]]),
      (source.range(of: "@end-ganit-table"), "", [[.unterminated]]),
    ]
    for (range, replacement, codes) in cases {
      var expected = original
      edit(editor, &expected, range, replacement)
      try await expectQuarantined(editor, textView, expected)
      let broken = try #require(editor.latestEvaluation)
      #expect(broken.tables.map { $0.diagnostics.map(\.code) } == codes)
      #expect(broken.tables.allSatisfy { $0.projection == nil })
      editor.documentUndoManager.undo()
      try await expectQuarantined(editor, textView, original, codes: [])
      #expect(editor.latestEvaluation?.tables.map(\.projection) == [table])
      editor.documentUndoManager.redo()
      try await expectQuarantined(editor, textView, expected)
      #expect(editor.latestEvaluation?.tables.allSatisfy { $0.projection == nil } == true)
      editor.documentUndoManager.undo()
      try await expectQuarantined(editor, textView, original, codes: [])
    }
  }

  /// A superseded generation cannot commit after a newer one, so an older
  /// valid table never replaces a newer invalid block.
  @Test
  func onlyTheNewestGenerationCommits() async throws {
    let valid = try Self.fixture("line-endings-lf.txt")
    let invalid = valid.replacingOccurrences(of: "\"t\": 0", with: "\"t\": ")
    let recorder = CommitRecorder()
    let scheduler = SheetEvaluationScheduler(context: try testContext()) {
      _, evaluation, interval in
      interval.cancel()
      recorder.commits.append(evaluation)
    }
    var commits: [SheetEvaluation] { recorder.commits }
    // Generation 1 starts and moves to the worker, then finishes evaluating
    // while the main actor is busy, so its commit is still waiting for the
    // main actor when generation 2 is scheduled.
    scheduler.schedule(SheetSource(valid))
    await Task.yield()
    usleep(500_000)
    scheduler.schedule(SheetSource(invalid))
    await scheduler.waitUntilIdle()
    #expect(commits.count == 1)
    // Both generations evaluated; only the newer one committed.
    #expect(commits.first?.generation == 2)
    #expect(commits.last?.tables.map { $0.diagnostics.map(\.code) } == [[.malformed]])
    #expect(commits.last?.tables.first?.projection == nil)

    // Repairing commits the table again; breaking it again withholds it.
    scheduler.schedule(SheetSource(valid))
    await scheduler.waitUntilIdle()
    #expect(commits.last?.tables.first?.projection != nil)
    scheduler.schedule(SheetSource(invalid))
    scheduler.schedule(SheetSource(valid))
    scheduler.schedule(SheetSource(invalid))
    await scheduler.waitUntilIdle()
    #expect(commits.count == 3)
    #expect(commits.last?.tables.first?.projection == nil)
    #expect(commits.map(\.generation) == commits.map(\.generation).sorted())
  }

  /// Block lines are never sent to the assistant, while prose it could not
  /// work out still is.
  @Test
  func blockLinesNeverAskTheAssistant() async throws {
    let source = try Self.fixture("unsupported-version.txt") + "10 kg of water in ml"
    let (editor, _) = try await makeEditor(source, markdown: false)
    let asked = AskedLines()
    editor.assistantPause = .milliseconds(10)
    editor.askAssistant = { line in
      await asked.record(line)
      return nil
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while await asked.lines.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await asked.lines == ["10 kg of water in ml"])
    #expect(editor.latestEvaluation?.lines.allSatisfy(\.assistantPrompts.isEmpty) == true)
  }

  // MARK: Helpers

  /// The text matches byte for byte, block lines of the newest evaluation
  /// have no answers, declarations or prompts, and a block with diagnostics
  /// has no projection.
  private func expectQuarantined(
    _ editor: SheetEditorViewController, _ textView: SheetTextView, _ expected: String,
    codes: [TableSourceDiagnostic.Code]? = nil,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) async throws {
    #expect(textView.string.utf8.elementsEqual(expected.utf8), sourceLocation: sourceLocation)
    #expect(editor.sheet.text.utf8.elementsEqual(expected.utf8), sourceLocation: sourceLocation)
    await editor.scheduler?.waitUntilIdle()
    let evaluation = try #require(editor.latestEvaluation, sourceLocation: sourceLocation)
    #expect(
      evaluation.lines.map(\.id) == editor.sheet.lines.map(\.id), sourceLocation: sourceLocation)
    let blocks = TableSourceDocument.blockLineRanges(in: editor.sheet)
    #expect(evaluation.tables.map(\.physicalLines) == blocks, sourceLocation: sourceLocation)
    #expect(
      evaluation.tables.allSatisfy { $0.diagnostics.isEmpty || $0.projection == nil },
      sourceLocation: sourceLocation)
    if let codes {
      #expect(evaluation.tableDiagnostics.map(\.code) == codes, sourceLocation: sourceLocation)
    }
    let answered = Set(textView.answerLayout(in: textView.bounds).map(\.line))
    for line in blocks.joined().map({ evaluation.lines[$0] }) {
      #expect(
        line.result == nil && line.declaredVariableName == nil, sourceLocation: sourceLocation)
      #expect(line.assistantPrompts.isEmpty, sourceLocation: sourceLocation)
      #expect(textView.answer(line.id) == nil, sourceLocation: sourceLocation)
      #expect(!answered.contains(line.id), sourceLocation: sourceLocation)
    }
  }

  /// One undoable edit, applied to `expected` as well.
  private func edit(
    _ editor: SheetEditorViewController, _ expected: inout String, _ range: NSRange,
    _ replacement: String
  ) {
    editor.textView.breakUndoCoalescing()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(replacement, replacementRange: range)
    editor.documentUndoManager.endUndoGrouping()
    expected = (expected as NSString).replacingCharacters(in: range, with: replacement)
  }

  private func utf16Start(ofLine index: Int, in text: String) -> Int {
    SheetSource(text).lines.prefix(index).reduce(0) {
      $0 + $1.text.utf16.count + ($1.terminator?.rawValue.utf16.count ?? 0)
    }
  }

  private static var windows: [NSWindow] = []

  /// An editor in a window. Without grouping by event, each `edit` is one
  /// undo step.
  private func makeEditor(_ text: String, markdown: Bool, groupsUndoByEvent: Bool = false)
    async throws -> (SheetEditorViewController, SheetTextView)
  {
    var display = DisplayOptions.standard
    display.writesAnswersInline = markdown
    let editor = SheetEditorViewController(text: text, context: try testContext(), display: display)
    editor.documentUndoManager.groupsByEvent = groupsUndoByEvent
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
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
private final class CommitRecorder {
  var commits: [SheetEvaluation] = []
}

private actor AskedLines {
  private(set) var lines: [String] = []

  func record(_ line: String) {
    lines.append(line)
  }
}
