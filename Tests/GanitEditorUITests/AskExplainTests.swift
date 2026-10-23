import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitSuggestionProtocol
import Testing

@testable import GanitEditorUI

@MainActor
@Suite(.serialized)
struct AskExplainTests {
  private static var windows: [NSWindow] = []

  private func context() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
  }

  private func editor(_ source: String) async throws -> SheetEditorViewController {
    let editor = SheetEditorViewController(text: source, context: try context())
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    editor.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    return editor
  }

  private func configure(_ editor: SheetEditorViewController, reply: Data = Data())
    -> ExplainTransport
  {
    let transport = ExplainTransport(reply: reply)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "explain"))
    return transport
  }

  private func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }

  private func texts(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
  }

  private func card(_ editor: SheetEditorViewController) throws -> InterpretationViewController {
    let textView = try #require(editor.textView as? SheetTextView)
    return try #require(
      textView.interpretationPopover?.contentViewController as? InterpretationViewController)
  }

  private func replace(_ editor: SheetEditorViewController, range: NSRange, with text: String) {
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(text, replacementRange: range)
    editor.documentUndoManager.endUndoGrouping()
  }

  @Test func the920QuestionUsesTheEngineCardAndSendsNothing() async throws {
    let source = "subtotal = 9200\n10% of line 1"
    let editor = try await editor(source)
    let transport = configure(editor)
    editor.suggestionSession.prepare(instruction: "why is this 920?", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(!editor.suggestionSession.isVisible)
    #expect(await transport.count() == 0)
    #expect(editor.sheet.text == source)
    let rows = editor.explanationDetails(for: editor.sheet.lines[1].id)
    #expect(rows.contains { $0.label == "Expression" && $0.value == "10% of line 1" })
    #expect(rows.contains { $0.label == "Result" && $0.value == "920" })
    #expect(rows.contains { $0.label == "Full precision" && $0.value == "920" })
    #expect(rows.contains { $0.label == "Reads" && $0.value.contains("subtotal") })
    #expect(rows.contains { $0.label == "Rule" && $0.value.contains("%") })
    #expect(rows.contains { $0.value.contains("Nothing was sent to a model.") })
    let controls = buttons(try card(editor).view)
    #expect(controls.contains { $0.title == "Ask the model instead" })
    #expect(controls.contains { $0.title == "Dismiss" })
    #expect(!controls.contains { $0.title == "Fix it" })
  }

  @Test func theModelFallbackWaitsForReturnAndKeepsTheOriginalQuestion() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 1")
    let pasteboard = NSPasteboard.withUniqueName()
    editor.resultPasteboard = pasteboard
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "explanation",
      "text": "A percentage takes a share of the subtotal.",
    ])
    let transport = configure(editor, reply: reply)
    editor.suggestionSession.prepare(instruction: "why is this 920?", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    let button = try #require(
      buttons(try card(editor).view).first { $0.title == "Ask the model instead" })
    button.performClick(nil)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    #expect(editor.suggestionSession.instruction == "why is this 920?")
    #expect(await transport.count() == 0)
    editor.suggestionSession.send()
    await editor.suggestionSession.waitUntilIdle()
    #expect(await transport.count() == 1)
    #expect(!editor.suggestionSession.canApply)
    #expect(editor.suggestionSession.preview == nil)
    let words = texts(try card(editor).view)
    #expect(words.contains { $0.contains("Model explanation.") })
    #expect(words.contains("A percentage takes a share of the subtotal."))
    #expect(words.contains { $0.contains("Context was sent") })
    #expect(words.contains("explain"))
    let copy = try #require(buttons(try card(editor).view).first { $0.title == "Copy" })
    copy.performClick(nil)
    #expect(
      pasteboard.string(forType: .string) == "A percentage takes a share of the subtotal."
    )
    #expect(editor.sheet.text == "subtotal = 9200\n10% of line 1")
  }

  @Test func fixItPreparesTheDiagnosticAndOnlyACheckedProposalCanChangeSource() async throws {
    let source = "2 + (3"
    let editor = try await editor(source)
    let target = editor.sheet.lines[0].id
    let snapshot = try await editor.suggestionSnapshot(target: target)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "fix", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3")], bindings: [],
      literals: try ["2", "3"].map { number in
        SuggestionLiteral(
          text: number,
          evidence: try #require(
            evidence.first { $0.kind == "literal" && $0.text == number }?.handle))
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: [], summary: "Add the two numbers.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
    let transport = configure(editor, reply: reply)
    editor.suggestionSession.prepare(instruction: "why does this fail?", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    let diagnostic = try #require(
      editor.explanationDetails(for: target).first { $0.label == "Problem" }?.value)
    #expect(!diagnostic.isEmpty)
    #expect(await transport.count() == 0)
    let fix = try #require(buttons(try card(editor).view).first { $0.title == "Fix it" })
    fix.performClick(nil)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    #expect(editor.suggestionSession.instruction.hasPrefix("Fix this calculation."))
    let body = try #require(editor.suggestionSession.preparedBody)
    #expect(String(decoding: body, as: UTF8.self).contains("syntax.expectedClosingParenthesis"))
    #expect(await transport.count() == 0)
    #expect(editor.sheet.text == source)
    editor.suggestionSession.send()
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.canApply)
    #expect(editor.sheet.text == source)
    #expect(await transport.count() == 1)
    editor.suggestionSession.apply()
    await editor.suggestionSession.waitUntilIdle()
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.sheet.text.contains("2 + 3"))
    let expected = CalculationEngine().evaluate("5", context: try context())
    #expect(editor.latestEvaluation?.lines.contains { $0.result == expected } == true)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == source)
  }

  @Test func deletingAReferencedLineShowsTheActualBrokenReference() async throws {
    let editor = try await editor("10\n20 + 30\nline 2 + line 2")
    let transport = configure(editor)
    replace(editor, range: NSRange(location: 3, length: 8), with: "")
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.sheet.text == "10\n@deleted + @deleted")
    let target = editor.sheet.lines[1].id
    let textView = try #require(editor.textView as? SheetTextView)
    let diagnostic = try #require(textView.interpretation(target).first { $0.label == "Problem" })
    let rows = editor.explanationDetails(for: target)
    #expect(rows.contains(diagnostic))
    #expect(!rows.contains { $0.label == "Cause" })
    #expect(!rows.contains { $0.value.contains("Netflix") })
    #expect(editor.showLocalExplanation(instruction: "why does this fail?") == .shown)
    #expect(await transport.count() == 0)
    #expect(buttons(try card(editor).view).contains { $0.title == "Fix it" })
  }

  @Test func aValidLineReferenceDoesNotAcquireAnInventedFailure() async throws {
    let editor = try await editor("salary = 62000\nNetflix = 649\nsavings = salary - line 2")
    let rows = editor.explanationDetails(for: editor.sheet.lines[2].id)
    #expect(rows.contains { $0.label == "Result" && $0.value == "61,351" })
    #expect(!rows.contains { $0.label == "Problem" || $0.label == "Cause" })
  }

  @Test func aLocalQuestionDuringEvaluationDoesNotFallThroughToTheProvider() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 1")
    let transport = configure(editor)
    replace(editor, range: NSRange(location: 11, length: 4), with: "10000")
    editor.suggestionSession.prepare(instruction: "why is this 920?", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(await transport.count() == 0)
    #expect(editor.suggestionSession.preparedBody == nil)
    #expect(!editor.suggestionSession.canApply)
  }

  @Test func anOldCardsModelActionCannotUseANewEvaluation() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 1")
    let transport = configure(editor)
    editor.suggestionSession.prepare(instruction: "why is this 920?", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    let fallback = try #require(
      buttons(try card(editor).view).first { $0.title == "Ask the model instead" })
    replace(editor, range: NSRange(location: 11, length: 4), with: "10000")
    await editor.scheduler?.waitUntilIdle()
    fallback.performClick(nil)
    await editor.suggestionSession.waitUntilIdle()
    #expect(!editor.suggestionSession.isVisible)
    #expect(await transport.count() == 0)
  }

  @Test func sourceChangesRefuseThePreviousExplanationUntilEvaluationFinishes() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 1")
    let target = editor.sheet.lines[1].id
    replace(editor, range: NSRange(location: 11, length: 4), with: "10000")
    #expect(editor.explanationDetails(for: target).isEmpty)
    #expect(editor.showLocalExplanation(instruction: "why is this 920?") != .shown)
    await editor.scheduler?.waitUntilIdle()
    let rows = editor.explanationDetails(for: target)
    #expect(rows.contains { $0.label == "Result" && $0.value == "1,000" })
    #expect(!rows.contains { $0.label == "Result" && $0.value == "920" })
  }

  @Test func aReferenceToALineThatStoppedBeingACalculationNamesIt() async throws {
    let editor = try await editor("salary = 62000\nnet = 41000\nsavings = salary - line 2")
    let transport = configure(editor)
    // The reader turned the line `line 2` read into a heading. The reference is
    // intact and now reads a line with no answer; Ganit says what it reads now.
    replace(editor, range: NSRange(location: 15, length: 11), with: "# net")
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.sheet.text == "salary = 62000\n# net\nsavings = salary - line 2")
    let rows = editor.explanationDetails(for: editor.sheet.lines[2].id)
    let cause = try #require(rows.first { $0.label == "Cause" })
    #expect(cause.value.contains("line 2"))
    #expect(cause.value.contains("# net"))
    #expect(cause.value.contains("a line added or removed above"))
    #expect(cause.lineNumber == 2)
    #expect(rows.contains { $0.label == "Problem" })
    #expect(editor.showLocalExplanation(instruction: "why does this fail?") == .shown)
    #expect(await transport.count() == 0)
    // The cause is selectable: it takes the reader to the line it names.
    let jump = try #require(
      buttons(try card(editor).view).first { $0.title.contains("line 2") })
    jump.performClick(nil)
    let selected = editor.textView.selectedRange()
    #expect(15..<20 ~= selected.location)
  }

  @Test func aCardWithoutAModelStillExplainsAndOffersNothingAI() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 1")
    editor.suggestionConfiguration = nil
    #expect(editor.showLocalExplanation(instruction: "why is this 920?") == .shown)
    let rows = editor.explanationDetails(for: editor.sheet.lines[1].id)
    #expect(rows.contains { $0.value.contains("Nothing was sent to a model.") })
    #expect(!rows.contains { $0.label == "Source" && $0.value.contains("Fix it") })
    let controls = buttons(try card(editor).view)
    #expect(controls.contains { $0.title == "Copy" })
    #expect(controls.contains { $0.title == "Dismiss" })
    #expect(!controls.contains { $0.title == "Fix it" })
    #expect(!controls.contains { $0.title == "Ask the model instead" })
  }

  @Test func aQuestionAboutANonCalculationLineGoesToTheModelAsAQuestion() async throws {
    let editor = try await editor("# Trip\n\nsubtotal = 9200")
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "explanation",
      "text": "A heading labels the sheet; it holds no calculation.",
    ])
    let transport = configure(editor, reply: reply)
    editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
    editor.suggestionSession.prepare(instruction: "explain this", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.allowsExplanationRequested)
    #expect(await transport.count() == 1)
    let body = String(decoding: try #require(await transport.requests.first?.body), as: UTF8.self)
    #expect(body.contains("The user explicitly requested an explanation"))
    #expect(body.contains("# Trip"))
    let words = texts(try card(editor).view)
    #expect(words.contains("A heading labels the sheet; it holds no calculation."))
    #expect(editor.sheet.text == "# Trip\n\nsubtotal = 9200")
  }

  @Test func aFailureCardInvitesTheFixItHandOff() async throws {
    let editor = try await editor("subtotal = 9200\n10% of line 9")
    _ = configure(editor)
    let rows = editor.explanationDetails(for: editor.sheet.lines[1].id)
    #expect(
      rows.contains {
        $0.label == "Source" && $0.value.contains("Nothing was sent to a model.")
          && $0.value.contains("Use Fix it")
      })
    #expect(editor.showLocalExplanation(instruction: "why does this fail?") == .shown)
    #expect(buttons(try card(editor).view).contains { $0.title == "Fix it" })
  }
  @Test func aPlainFactAnswerIsTransientAndCannotChangeTheSource() async throws {
    let source = "Which planet is known as the red planet?"
    let editor = try await editor(source)
    editor.view.window?.makeKeyAndOrderFront(nil)
    defer { editor.view.window?.orderOut(nil) }
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "answer", "text": "Mars.",
    ])
    let transport = configure(editor, reply: reply)
    editor.suggestionSession.prepare(autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(await transport.count() == 1)
    #expect(!editor.suggestionSession.isVisible)
    #expect(!editor.suggestionSession.canApply)
    #expect(editor.suggestionSession.preview == nil)
    let content = try card(editor).view
    let sheet = try #require(editor.textView as? SheetTextView)
    #expect((sheet.accessibilityChildren() ?? []).contains { ($0 as? NSView) === content })
    let parentMatches = content.accessibilityParent() as? SheetTextView === sheet
    #expect(parentMatches)
    #expect(content.isAccessibilityElement())
    #expect(texts(content).contains("Answer · Unverified"))
    #expect(texts(content).contains("Mars."))
    #expect(texts(content).contains { $0.contains("Context was sent") })
    #expect(Set(buttons(content).map(\.title)) == ["Copy", "Dismiss"])
    #expect(editor.sheet.text == source)
    #expect(!editor.documentUndoManager.canUndo)
    let exported = await editor.exportedLines()
    #expect(!exported.contains { $0.answer == "Mars." })
    editor.dismissExplanation()
    let cardIsClosed = (editor.textView as? SheetTextView)?.interpretationPopover?.isShown != true
    #expect(cardIsClosed)
  }

}

private actor ExplainTransport: SuggestionTransport {
  private let reply: Data
  private(set) var requests: [SuggestionWireRequest] = []
  private var calls = 0
  init(reply: Data) { self.reply = reply }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    calls += 1
    requests.append(request)
    return reply
  }
  func count() -> Int { calls }
}
