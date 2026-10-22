import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@testable import GanitEditorUI

/// M3's second half, seen the way the reader sees it: the water example reaches
/// Apply with one checked world fact, Ganit writes the origin comment itself,
/// the badge and the dots follow the dependency graph, and an edit to the value
/// sends no request and leaves nothing marked.
@MainActor
@Suite(.serialized)
struct AssumptionProvenanceTests {
  private static var windows: [NSWindow] = []

  private static let waterSource = "mass = 10 kg\nFind the volume of this water in ml."
  private static let basis = "Density of water at 4 °C"
  /// Ganit stamps the origin with the day the reader accepted the fact.
  private func marker() -> String { "// AI: \(Self.basis) · scenario · \(todayStamp())" }

  /// Today in UTC, worked out here rather than borrowed from the code under test.
  private func todayStamp() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: Date())
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  // MARK: harness

  private func makeContext() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
  }

  private func editor(_ source: String) async throws -> SheetEditorViewController {
    let editor = SheetEditorViewController(text: source, context: try makeContext())
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return editor
  }

  /// An expectation the sheet cannot influence: the engine reads this text on
  /// its own, outside the proposal.
  private func expected(_ text: String) throws -> CalculationResult {
    CalculationEngine().evaluate(text, context: try makeContext())
  }

  private func expectedValue(_ text: String) throws -> EngineValue {
    guard case .value(let value) = try expected(text) else {
      Issue.record("\(text) is not a value")
      throw ExpectationFailure()
    }
    return value
  }

  private struct ExpectationFailure: Error {}

  private func configure(_ editor: SheetEditorViewController, _ replies: [Data]) -> WaterTransport {
    let transport = WaterTransport(replies)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "scenario"))
    return transport
  }

  /// The mass sits on a line the reader did not ask about, so the model has to
  /// ask for it and the reader has to include it. That is the disclosed path.
  private func needMass() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "need_context", "records": ["S1"],
      "reason": "The mass of the water is on another line.",
    ])
  }

  private func waterProposal() throws -> Data {
    let candidate = SuggestionCandidate(
      id: "water",
      edits: [
        SuggestionEdit(target: "T1", replacement: "density = 1 g/ml\nvolume = mass / density in ml")
      ],
      bindings: [
        SuggestionBinding(symbol: "mass", source: "S1"),
        SuggestionBinding(symbol: "density", source: "L1"),
      ],
      literals: [SuggestionLiteral(text: "1 g/ml", evidence: "A1")],
      relations: [SuggestionRelation(rule: "interpretation", evidence: "E1")],
      assumptions: [SuggestionAssumption(id: "A1", text: Self.basis, evidence: "E1")],
      summary: "Divide the mass by the density of water.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
  }

  private func cells(
    of editor: SheetEditorViewController, until settled: ([AnswerCell]) -> Bool = { _ in true }
  ) async throws -> [AnswerCell] {
    let textView = try #require(editor.textView as? SheetTextView)
    for _ in 0..<300 {
      let answers = textView.answerLayout(in: textView.bounds).map(\.cell)
      if settled(answers) { return answers }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The answers never settled.")
    return textView.answerLayout(in: textView.bounds).map(\.cell)
  }

  private func cell(
    of editor: SheetEditorViewController, _ id: LineID
  ) async throws -> AnswerCell {
    let textView = try #require(editor.textView as? SheetTextView)
    for _ in 0..<300 {
      if let answer = textView.answerLayout(in: textView.bounds).first(where: { $0.line == id }) {
        return answer.cell
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("No answer was drawn for line \(id).")
    return AnswerCell(text: "", fullPrecision: "")
  }

  private func layout(
    of editor: SheetEditorViewController, _ id: LineID
  ) -> (cell: AnswerCell, rect: NSRect)? {
    let textView = editor.textView as? SheetTextView
    return textView?.answerLayout(in: textView?.bounds ?? .zero).first { $0.line == id }
      .map { ($0.cell, $0.rect) }
  }

  private func line(_ editor: SheetEditorViewController, _ prefix: String) throws -> SheetLine {
    try #require(
      editor.sheet.lines.first { $0.text.hasPrefix(prefix) }, "No line starting \(prefix)")
  }

  private func result(_ editor: SheetEditorViewController, _ id: LineID) -> CalculationResult? {
    editor.latestEvaluation?.lines.first { $0.id == id }?.result
  }

  private func origin(_ editor: SheetEditorViewController, _ id: LineID) -> Set<LineID> {
    editor.latestEvaluation?.lines.first { $0.id == id }?.aiAssumptionOrigins ?? []
  }

  private func utf16(_ text: String, _ utf8: Range<Int>) -> NSRange? {
    let bytes = text.utf8
    guard
      let lower = bytes.index(
        bytes.startIndex, offsetBy: utf8.lowerBound, limitedBy: bytes.endIndex),
      let upper = bytes.index(
        bytes.startIndex, offsetBy: utf8.upperBound, limitedBy: bytes.endIndex),
      lower.samePosition(in: text.unicodeScalars) != nil,
      upper.samePosition(in: text.unicodeScalars) != nil
    else { return nil }
    let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
    return NSRange(location: start, length: text.utf16.distance(from: lower, to: upper))
  }

  /// A job that is waiting for the reader is not idle: it is parked on the
  /// consent continuation, so `waitUntilIdle()` would sit there until the
  /// deadline. Watch for the state instead.
  private func settle(
    _ editor: SheetEditorViewController, _ state: SuggestionJobState, timeout: Int = 400
  ) async throws {
    for _ in 0..<timeout {
      if editor.suggestionSession.state == state,
        state != .needsContext || !editor.suggestionSession.requestedContext.isEmpty
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(
      "Ask never reached \(state) with its records; it is \(editor.suggestionSession.state).")
  }

  /// The suite turns `groupsByEvent` off, so a test that types has to open the
  /// group an AppKit event would have opened. Real typing arrives inside one.
  private func type(
    _ editor: SheetEditorViewController, _ text: String, replacementRange: NSRange
  ) {
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(text, replacementRange: replacementRange)
    editor.documentUndoManager.endUndoGrouping()
  }

  private func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }

  /// The bar's labels live inside its stack view, so a bar's own subviews miss
  /// every sentence it says.
  private func texts(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
  }

  /// Open the Ask on the prose line and take it as far as a checked proposal
  /// that still needs the reader's approval of one assumed fact.
  private func ask(editor: SheetEditorViewController, transport: WaterTransport) async throws {
    let caret = NSRange(
      location: editor.textView.string.utf16.count, length: 0)
    editor.textView.setSelectedRange(caret)
    editor.suggestionSession.prepare(
      instruction: "Work out the volume of this water in millilitres.", autoSend: true)
    try await settle(editor, .needsContext)
    #expect(editor.suggestionSession.requestedContext.map(\.name) == ["mass"])
    #expect(await transport.count() == 1)
    editor.suggestionSession.includeContext()
    await editor.suggestionSession.waitUntilIdle()
    #expect(await transport.count() == 2)
  }

  private func applyWater(editor: SheetEditorViewController) async throws -> String {
    editor.suggestionSession.approve("A1", approved: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.canApply)
    editor.suggestionSession.apply()
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.state == .applied)
    await editor.scheduler?.waitUntilIdle()
    return editor.sheet.text
  }

  // MARK: the water example

  @Test func theWaterExampleReachesApplyWithOneCheckedFactGanitMarkedItself() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)

    let session = editor.suggestionSession
    let preview = try #require(session.preview)
    // Ganit never presents an assumed fact as though the reader had agreed to it.
    #expect(preview.requiresAssumptionApproval)
    #expect(preview.choices.isEmpty)
    #expect(!session.canApply)
    #expect(preview.candidate.assumptions.map(\.text) == [Self.basis])
    #expect(session.assumptions.isEmpty)
    // The engine, not the model, worked out the preview: 10 kg at 1 g/ml.
    let previewExpected = try expectedValue("10000 ml")
    #expect(preview.result == previewExpected)

    // The bar offers the basis as the thing to approve, in the reader's words,
    // and says why this number was assumed when a tax rate would have been asked for.
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    let words = texts(bar)
    #expect(
      words.contains(
        "Ganit asks when only you know; it assumes and marks when the world knows."))
    let approval = try #require(
      buttons(bar).first { $0.title == Self.basis })
    approval.performClick(nil)
    await session.waitUntilIdle()
    #expect(session.assumptions == ["A1"])
    #expect(session.canApply)

    session.apply()
    await session.waitUntilIdle()
    await editor.scheduler?.waitUntilIdle()
    #expect(session.state == .applied)
    #expect(await transport.count() == 2)
    let applied = editor.sheet.text

    // The fact is a plain declaration on its own line, with an origin Ganit wrote.
    let density = try line(editor, "density = ")
    #expect(density.text == "density = 1 g/ml \(marker())")
    let metadata = try #require(AIAssumption.parse(density.text, context: try makeContext()))
    #expect(metadata.basis == Self.basis)
    #expect(metadata.model == "scenario")
    #expect(metadata.date == todayStamp(), "unexpected date \(metadata.date)")
    let volume = try line(editor, "volume = ")
    let tenThousand = try expected("10000 ml")
    #expect(result(editor, volume.id) == tenThousand)
    // The reader's own words stay a record, and one origin comment is enough.
    #expect(editor.sheet.text.contains("// Request record: Find the volume"))
    #expect(editor.sheet.text.components(separatedBy: "// AI:").count == 2)

    // The badge sits on the declared value; the dots sit on what reads it.
    let densityCell = try await cell(of: editor, density.id)
    let volumeCell = try await cell(of: editor, line(editor, "volume = ").id)
    let massCell = try await cell(of: editor, line(editor, "mass = ").id)
    #expect(densityCell.isAIAssumption && !densityCell.isAIDerived)
    #expect(volumeCell.isAIDerived && !volumeCell.isAIAssumption)
    #expect(!massCell.isAIDerived && !massCell.isAIAssumption)
    let textView = try #require(editor.textView as? SheetTextView)
    #expect(textView.badgeWidth(for: densityCell) > 0)
    #expect(textView.badgeWidth(for: volumeCell) == 9 + SheetTextView.badgeGap)
    #expect(textView.badgeWidth(for: massCell) == 0)
    #expect(origin(editor, volume.id) == [density.id])
    #expect(applied.contains(marker()))
  }

  @Test func editingTheAssumedValueRecalculatesWithNoRequestAndLeavesNothingMarked() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    let marked = try await applyWater(editor: editor)
    let density = try line(editor, "density = ")
    let requestsBefore = await transport.count()
    #expect(requestsBefore == 2)

    // The reader corrects the number in the sheet, as they would any other value.
    let value = try #require(AIAssumption.valueRange(in: density.text))
    let range = try #require(
      utf16(
        editor.textView.string,
        density.range.lowerBound + value.lowerBound..<density.range.lowerBound + value.upperBound))
    #expect((editor.textView.string as NSString).substring(with: range) == "1 g/ml")
    editor.textView.setSelectedRange(range)
    type(editor, "2 g/ml", replacementRange: range)
    await editor.scheduler?.waitUntilIdle()

    // The comment, the badge and the dots went with the edit, in the same step.
    #expect(try line(editor, "density = ").text == "density = 2 g/ml")
    #expect(!editor.sheet.text.contains("// AI:"))
    let fiveThousand = try expected("5000 ml")
    let editedVolumeID = try line(editor, "volume = ").id
    let editedDensityID = try line(editor, "density = ").id
    #expect(await transport.count() == requestsBefore)
    #expect(result(editor, editedVolumeID) == fiveThousand)
    #expect(origin(editor, editedVolumeID).isEmpty)
    let densityCell = try await cell(of: editor, editedDensityID)
    let volumeCell = try await cell(of: editor, editedVolumeID)
    #expect(!densityCell.isAIAssumption && !densityCell.isAIDerived)
    #expect(!volumeCell.isAIAssumption && !volumeCell.isAIDerived)

    // One Undo step restores the exact bytes, and the marks come back with them.
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == marked)
    await editor.scheduler?.waitUntilIdle()
    let restoredVolumeID = try line(editor, "volume = ").id
    let restoredDensityID = try line(editor, "density = ").id
    let restoredVolume = try await cell(of: editor, restoredVolumeID)
    let restoredDensity = try await cell(of: editor, restoredDensityID)
    #expect(restoredVolume.isAIDerived)
    #expect(restoredDensity.isAIAssumption)
    #expect(await transport.count() == requestsBefore)
  }

  @Test func typingAfterTheValueStillDropsTheOriginAndKeepsTheCaret() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    _ = try await applyWater(editor: editor)
    let density = try line(editor, "density = ")
    let value = try #require(AIAssumption.valueRange(in: density.text))
    let end = try #require(
      utf16(
        editor.textView.string,
        (density.range.lowerBound + value.upperBound)..<(density.range.lowerBound + value.upperBound)
      ))

    editor.textView.setSelectedRange(end)
    type(editor, " * 2", replacementRange: end)
    await editor.scheduler?.waitUntilIdle()

    // The value is no longer a plain number, so it is no longer an assumption.
    #expect(try line(editor, "density = ").text == "density = 1 g/ml * 2")
    #expect(!editor.sheet.text.contains("// AI:"))
    let changedVolume = try line(editor, "volume = ").id
    #expect(origin(editor, changedVolume).isEmpty)
    #expect(editor.textView.selectedRange() == NSRange(location: end.location + 4, length: 0))
  }

  /// A selection that runs a character or two past the value, into the space
  /// before the origin, is still the reader correcting the number. It must not
  /// leave a marked value that no longer holds what was marked.
  @Test func aSelectionThatRunsPastTheValueStillDropsTheOrigin() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    _ = try await applyWater(editor: editor)
    let density = try line(editor, "density = ")
    let value = try #require(AIAssumption.valueRange(in: density.text))
    let range = try #require(
      utf16(
        editor.textView.string,
        density.range.lowerBound
          + value.lowerBound..<(density.range.lowerBound + value.upperBound
          + 1)))
    #expect((editor.textView.string as NSString).substring(with: range) == "1 g/ml ")
    editor.textView.setSelectedRange(range)
    type(editor, "2 g/ml", replacementRange: range)
    await editor.scheduler?.waitUntilIdle()
    #expect(try line(editor, "density = ").text == "density = 2 g/ml")
    #expect(!editor.sheet.text.contains("// AI:"))
    let volume = try line(editor, "volume = ")
    #expect(origin(editor, volume.id).isEmpty)
    let fiveThousand = try expected("5000 ml")
    #expect(result(editor, volume.id) == fiveThousand)
  }

  /// Two cursors at once, one in the value and one in the origin, cannot be
  /// expressed as one row rewrite. Ganit declines the interception and lets
  /// ordinary typing have the row rather than patch the same bytes twice.
  @Test func twoCursorsAcrossTheValueAndTheOriginAreLeftToOrdinaryTyping() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    _ = try await applyWater(editor: editor)
    let before = editor.sheet.text
    let density = try line(editor, "density = ")
    let value = try #require(AIAssumption.valueRange(in: density.text))
    let inValue = try #require(
      utf16(
        editor.textView.string,
        density.range.lowerBound + value.lowerBound..<density.range.lowerBound + value.upperBound))
    let inMarker = try #require(
      utf16(
        editor.textView.string,
        density.range.lowerBound + value.upperBound + 3..<density.range.lowerBound
          + value.upperBound + 4))
    let delegate = try #require(editor.textView.delegate)
    let accepted =
      delegate.textView?(
        editor.textView,
        shouldChangeTextInRanges: [
          NSValue(range: inValue), NSValue(range: inMarker),
        ],
        replacementStrings: ["2 g/ml", "x"]) ?? false
    #expect(accepted, "Ordinary typing must still be allowed to change the row")
    #expect(editor.sheet.text == before)
    // A plain single-cursor edit of the same value afterwards still marks the
    // difference: declining one interception does not disable the next.
    editor.textView.setSelectedRange(inValue)
    type(editor, "2 g/ml", replacementRange: inValue)
    await editor.scheduler?.waitUntilIdle()
    #expect(try line(editor, "density = ").text == "density = 2 g/ml")
    #expect(!editor.sheet.text.contains("// AI:"))
  }

  @Test func anEditOutsideTheAssumedValueLeavesTheOriginAlone() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    _ = try await applyWater(editor: editor)

    let volume = try line(editor, "volume = ")
    let range = try #require(
      utf16(editor.textView.string, volume.range.lowerBound..<volume.range.lowerBound))
    editor.textView.setSelectedRange(range)
    type(editor, "# check\n", replacementRange: range)
    await editor.scheduler?.waitUntilIdle()

    #expect(editor.sheet.text.contains("density = 1 g/ml \(marker())"))
    let keptDensity = try await cell(of: editor, line(editor, "density = ").id)
    let keptVolume = try await cell(of: editor, line(editor, "volume = ").id)
    #expect(keptDensity.isAIAssumption)
    #expect(keptVolume.isAIDerived)
  }

  @Test func theBadgeAndTheDotBothOpenTheCardAndTheSettingHidesOnlyTheDots() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    _ = try await applyWater(editor: editor)
    let textView = try #require(editor.textView as? SheetTextView)
    let density = try line(editor, "density = ")
    let volume = try line(editor, "volume = ")
    let mass = try line(editor, "mass = ")

    var opened: [LineID] = []
    textView.onInspectAssumption = { id, _ in opened.append(id) }
    for (id, marked) in [(density.id, true), (volume.id, true), (mass.id, false)] {
      let answer = try #require(layout(of: editor, id), "no answer for \(id)")
      let point = CGPoint(x: answer.rect.minX + 2, y: answer.rect.midY)
      let hit = textView.assumptionBadgeHit(at: point)
      if marked {
        #expect(hit?.line == id, "badge missing on line \(id)")
        textView.onInspectAssumption(try #require(hit?.line), try #require(hit?.rect))
      } else {
        #expect(hit == nil)
      }
    }
    #expect(opened == [density.id, volume.id])

    // View ▸ Mark AI-derived answers hides the dots, never the origin badge.
    editor.markAIDerivedAnswers = false
    let hiddenDensity = try await cell(of: editor, density.id)
    let hiddenVolume = try await cell(of: editor, volume.id)
    #expect(hiddenDensity.isAIAssumption)
    #expect(!hiddenVolume.isAIDerived)
    #expect(textView.badgeWidth(for: hiddenVolume) == 0)
    editor.markAIDerivedAnswers = true
    let shownVolume = try await cell(of: editor, volume.id)
    #expect(shownVolume.isAIDerived)
  }

  @Test func removingAnAssumptionPreviewsWhatBreaksThenRemovesItAsOneNamedStep() async throws {
    let editor = try await editor(Self.waterSource)
    let transport = configure(editor, [try needMass(), try waterProposal()])
    try await ask(editor: editor, transport: transport)
    let marked = try await applyWater(editor: editor)
    let density = try line(editor, "density = ")
    let volumeID = try line(editor, "volume = ").id
    #expect(editor.assumptionUsers(density.id).map(\.text) == ["volume = mass / density in ml"])

    let review = try await editor.reviewAssumptionRemoval(density.id)
    #expect(
      !review.sourceAfter.components(separatedBy: "\n").contains { $0.hasPrefix("density = ") })
    #expect(review.failures.count == 1)
    #expect(review.failures[0].contains("volume = mass / density in ml"))
    // A preview never touches the sheet, and it is not an Apply.
    #expect(editor.sheet.text == marked)

    try editor.removeAssumption(review)
    await editor.scheduler?.waitUntilIdle()
    #expect(!editor.sheet.lines.contains { $0.text.hasPrefix("density = ") })
    #expect(!editor.sheet.text.contains("// AI:"))
    let tenThousandAgain = try expected("10000 ml")
    #expect(result(editor, volumeID) != tenThousandAgain)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == marked)
    await editor.scheduler?.waitUntilIdle()
    let backVolume = try await cell(of: editor, line(editor, "volume = ").id)
    #expect(backVolume.isAIDerived)
  }

  @Test func aCardThatWasNeverReviewedCannotRemoveAnything() async throws {
    let copied = "density = 1 g/ml \(marker())"
    var changed = 0
    var removed = 0
    var previews = 0
    let card = AssumptionCardController(
      details: [
        ("Value", "1 g/ml"), ("Basis", Self.basis), ("Model", "scenario"),
        ("Date", todayStamp()), ("Used by", "volume = mass / density in ml"),
      ],
      copiedSource: copied,
      change: { changed += 1 },
      preview: {
        previews += 1
        return "These lines fail when this value is removed:\nvolume = mass / density in ml"
      },
      remove: { removed += 1 })
    card.loadView()
    let buttons =
      card.view.subviews.compactMap { $0 as? NSStackView }
      .flatMap { $0.arrangedSubviews }.compactMap { $0 as? NSButton }
    let remove = try #require(buttons.first { $0.title == "Remove" })
    remove.performClick(nil)
    // The first click only previews what breaks.
    #expect(!remove.isEnabled)
    try await Task.sleep(for: .milliseconds(50))
    #expect(previews == 1)
    #expect(removed == 0)
    #expect(remove.isEnabled)
    #expect(remove.title == "Remove value")
    remove.performClick(nil)
    #expect(removed == 1)
    let change = try #require(buttons.first { $0.title == "Change value…" })
    change.performClick(nil)
    #expect(changed == 1)
    let copy = try #require(buttons.first { $0.title == "Copy" })
    NSPasteboard.general.clearContents()
    copy.performClick(nil)
    #expect(NSPasteboard.general.string(forType: .string) == copied)
  }
}

private actor WaterTransport: SuggestionTransport {
  private var replies: [Data]
  private var requests = 0
  init(_ replies: [Data]) { self.replies = replies }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    requests += 1
    guard !replies.isEmpty else { throw SuggestionTransportError.malformedCompletion }
    return replies.removeFirst()
  }
  func count() -> Int { requests }
}
