import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitFormatting
import GanitSuggestionProtocol
import Testing

@testable import GanitEditorUI

@MainActor
@Suite(.serialized)
struct SheetSuggestionTests {
  private static var windows: [NSWindow] = []
  private let request = "Add two and three."

  private func context() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
  }

  private func editor(_ text: String, surface: SheetSurface = .workspace, markdown: Bool = false)
    async throws -> SheetEditorViewController
  {
    var display = DisplayOptions.standard
    display.writesAnswersInline = markdown
    let editor = SheetEditorViewController(
      text: text, context: try context(), display: display, surface: surface)
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    return editor
  }

  private func proposal(
    _ editor: SheetEditorViewController, target: Int = 0, assumption: Bool = false
  ) async throws -> Data {
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[target].id)
    let evidence = snapshot.evidence()
    func handle(_ text: String, _ kind: String) throws -> String {
      try #require(evidence.first { $0.text == text && $0.kind == kind }?.handle)
    }
    let relation = try #require(
      evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle)
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3")], bindings: [],
      literals: [
        SuggestionLiteral(text: "2", evidence: try handle("two", "literal")),
        SuggestionLiteral(text: "3", evidence: try handle("three", "literal")),
      ],
      relations: [SuggestionRelation(rule: "interpretation", evidence: relation)],
      assumptions: assumption
        ? [SuggestionAssumption(id: "A1", text: "Use equal weights.", evidence: relation)] : [],
      summary: "Add the supplied numbers.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    return try JSONSerialization.data(
      withJSONObject: ["schemaVersion": 1, "kind": "proposal", "candidates": [object]],
      options: [.sortedKeys])
  }

  private func configure(_ editor: SheetEditorViewController, replies: [Data?])
    -> EditorSuggestionTransport
  {
    let transport = EditorSuggestionTransport(replies)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "synthetic"))
    return transport
  }

  /// Programmatic selection does not go through the delegate, and the selection
  /// summary is fed from there, so a test has to say it out loud.
  private func select(_ editor: SheetEditorViewController, _ range: NSRange) {
    editor.textView.setSelectedRange(range)
    editor.textView.delegate?.textViewDidChangeSelection?(
      Notification(name: NSTextView.didChangeSelectionNotification, object: editor.textView))
    editor.view.layoutSubtreeIfNeeded()
  }

  @Test func scopeReviewMakesZeroRequestsAndSendingShowsACheckedPreviewWithoutChangingSource()
    async throws
  {
    let editor = try await editor(request)
    let transport = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    #expect(session.canSend)
    #expect(await transport.count() == 0)
    let body = try #require(session.preparedBody)
    #expect(String(decoding: body, as: UTF8.self).contains(request))
    session.send()
    await session.waitUntilIdle()
    #expect(await transport.count() == 1)
    #expect(session.requestBodies == [body])
    #expect(session.canApply)
    #expect(editor.sheet.text == request)
    #expect(editor.latestEvaluation?.lines[0].result != .value(.number(.integer(IntegerValue(5)))))
    #expect((await editor.exportedLines())[0].source == request)
    session.dismiss()
    #expect(!session.isVisible)
    #expect(!editor.documentUndoManager.canUndo)
  }

  @Test(arguments: [false, true])
  func applicationUsesOneUndoAndOrdinarySavedSource(_ markdown: Bool) async throws {
    let original = request + "\nx = 8\n@2 + @1"
    let editor = try await editor(original, markdown: markdown)
    editor.textView.setSelectedRange(NSRange(location: 0, length: request.utf16.count))
    let beforeSelection = editor.textView.selectedRange()
    let transport = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    session.apply()
    await session.waitUntilIdle()
    #expect(session.state == .applied)
    #expect(editor.sheet.text == "2 + 3\n// Request record: " + request + "\nx = 8\n@3 + @1")
    #expect(editor.documentUndoManager.undoActionName == "Apply AI change")
    let accepted = editor.sheet.text
    await editor.scheduler?.waitUntilIdle()
    #expect(
      editor.latestEvaluation?.lines.last?.result == .value(.number(.integer(IntegerValue(13)))))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == original)
    #expect(editor.textView.selectedRange() == beforeSelection)
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == accepted)
    let reopened = try await self.editor(accepted, markdown: markdown)
    #expect(
      reopened.latestEvaluation?.lines[0].result == .value(.number(.integer(IntegerValue(5)))))
    #expect(await transport.count() == 1)
  }

  @Test func quickGanitUsesTheSameExplicitSourcePath() async throws {
    let editor = try await editor(request, surface: .quickGanit)
    let transport = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text == "2 + 3\n// Request record: " + request)
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText("20", replacementRange: NSRange(location: 0, length: 1))
    editor.documentUndoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.lines[0].result == .value(.number(.integer(IntegerValue(23)))))
    #expect(await transport.count() == 1)
  }

  @Test func sourceEditsAndDismissalIgnoreLateReplies() async throws {
    for dismiss in [false, true] {
      let editor = try await editor(request)
      let reply = try await proposal(editor)
      let transport = configure(editor, replies: [nil])
      let session = editor.suggestionSession
      session.prepare()
      await session.waitUntilIdle()
      session.send()
      await transport.waitForRequest()
      if dismiss {
        session.dismiss()
      } else {
        editor.documentUndoManager.beginUndoGrouping()
        editor.textView.insertText(
          "!", replacementRange: NSRange(location: request.utf16.count, length: 0))
        editor.documentUndoManager.endUndoGrouping()
      }
      await session.waitUntilIdle()
      await transport.complete(reply)
      #expect(!session.canApply)
      #expect(!session.isVisible || session.state == .stale)
      #expect(editor.sheet.text == request + (dismiss ? "" : "!"))
    }
  }

  @Test func assumptionsBlockApplyAndApprovedWorkingEntersSource() async throws {
    let editor = try await editor(request)
    let transport = configure(editor, replies: [try await proposal(editor, assumption: true)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    #expect(session.state == .needsChoice)
    #expect(!session.canApply)
    session.apply()
    #expect(editor.sheet.text == request)
    session.approve("A1", approved: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text.hasSuffix("// Approved assumption: Use equal weights."))
    #expect(await transport.count() == 1)
  }

  @Test func aClarificationStartsANewReviewedJobAndKeepsItsConstraint() async throws {
    let editor = try await editor(request)
    let clarify = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "clarify", "question": "Which addition rule applies?",
      "choices": ["Use equal weights."],
    ])
    let transport = configure(editor, replies: [clarify, try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    #expect(session.clarification != nil)
    session.submitClarification("Use equal weights.")
    await session.waitUntilIdle()
    #expect(session.canSend)
    #expect(await transport.count() == 1)
    #expect(
      String(decoding: try #require(session.preparedBody), as: UTF8.self).contains(
        "Use equal weights."))
    session.send()
    await session.waitUntilIdle()
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text.hasSuffix("// Task record: Use equal weights."))
    #expect(await transport.count() == 2)
  }

  @Test func escapeDismissesTheSuggestionBeforeTheParentResponder() async throws {
    let editor = try await editor(request, surface: .quickGanit)
    let transport = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    let text = try #require(editor.textView as? SheetTextView)
    text.complete(nil)
    #expect(!session.isVisible)
    #expect(editor.sheet.text == request)
    #expect(await transport.count() == 1)
  }

  @Test func tabAcceptsOnlyWithExplicitSuggestionControlFocusAndReturnEdits() async throws {
    for key in ["\t", "\r"] {
      let editor = try await editor(request)
      _ = configure(editor, replies: [try await proposal(editor)])
      let session = editor.suggestionSession
      session.prepare()
      await session.waitUntilIdle()
      session.send()
      await session.waitUntilIdle()
      editor.view.layoutSubtreeIfNeeded()
      func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
      }
      editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
      let apply = try #require(buttons(editor.view).first { $0.title == "Apply ⌘↩" })
      #expect(editor.view.window?.makeFirstResponder(apply) == true)
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: editor.view.window?.windowNumber ?? 0,
          context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
          keyCode: key == "\t" ? 48 : 36))
      if key == "\r" { editor.documentUndoManager.beginUndoGrouping() }
      apply.keyDown(with: event)
      if key == "\r" { editor.documentUndoManager.endUndoGrouping() }
      await session.waitUntilIdle()
      if key == "\t" {
        #expect(session.state == .applied)
        #expect(editor.sheet.text.hasPrefix("2 + 3"))
      } else {
        #expect(session.state == .stale)
        #expect(!editor.sheet.text.contains("2 + 3"))
        #expect(editor.sheet.text.hasPrefix("\n"))
      }
    }
  }

  @Test func ordinaryTabDoesNotApplyAndTheMinimumQuickWindowKeepsSourceSpace() async throws {
    let editor = try await editor(request, surface: .quickGanit)
    _ = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    editor.view.frame.size = NSSize(width: 380, height: 120)
    editor.viewDidLayout()
    #expect(editor.scrollView.frame.height >= 80)
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertTab(nil)
    editor.documentUndoManager.endUndoGrouping()
    #expect(session.state != .applied)
    #expect(!editor.sheet.text.contains("2 + 3"))
  }

  @Test func anExplicitInputRevisionIsInspectedSentAndSavedAsWorking() async throws {
    let editor = try await editor("4 / 0")
    let clarify = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "clarify",
      "question": "Which denominator should I use?", "choices": [],
      "missingInput": "A nonzero denominator",
    ])
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[0].id)
      .addingTaskNote("Use 2 as the denominator.")
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "4 / 2")],
      bindings: [],
      literals: [
        SuggestionLiteral(
          text: "4", evidence: try #require(evidence.first { $0.text == "4" }?.handle)),
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "2" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "N1" }?.handle))
      ],
      assumptions: [], summary: "Use the user-supplied denominator.")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let proposal = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
    let transport = configure(editor, replies: [clarify, proposal])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    session.submitClarification("Use 2 as the denominator.", revisesInputs: true)
    await session.waitUntilIdle()
    let body = try #require(session.preparedBody)
    #expect(String(decoding: body, as: UTF8.self).contains("userRevisedInputs"))
    session.send()
    await session.waitUntilIdle()
    #expect(session.requestBodies.last == body)
    #expect(session.canApply)
    session.apply()
    await session.waitUntilIdle()
    await editor.scheduler?.waitUntilIdle()
    #expect(editor.latestEvaluation?.lines[0].result == .value(.number(.integer(IntegerValue(2)))))
    #expect(
      editor.sheet.text
        == "4 / 2\n// Request record: 4 / 0\n// Task record: Use 2 as the denominator.")
    #expect(await transport.count() == 2)
  }

  @Test(arguments: [false, true])
  func aSelectedParagraphAndCompleteWorkingUseOneUndo(_ markdown: Bool) async throws {
    let original = request + "\nKeep the addition equal."
    let editor = try await editor(original, markdown: markdown)
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1",
      edits: [SuggestionEdit(target: "T1", replacement: "part = 2 + 3\nresult = part * 1")],
      bindings: [SuggestionBinding(symbol: "part", source: "L1")],
      literals: [
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle)),
        SuggestionLiteral(
          text: "3", evidence: try #require(evidence.first { $0.text == "three" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ], assumptions: [], summary: "Add the supplied numbers.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
    let transport = configure(editor, replies: [reply])
    editor.textView.setSelectedRange(NSRange(location: 0, length: original.utf16.count))
    let beforeSelection = editor.textView.selectedRange()
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    #expect(session.canSend)
    #expect(
      String(decoding: try #require(session.preparedBody), as: UTF8.self).contains(
        "Keep the addition equal."))
    session.send()
    await session.waitUntilIdle()
    #expect(session.preview?.result == .number(.integer(IntegerValue(5))))
    session.apply()
    await session.waitUntilIdle()
    #expect(
      editor.sheet.text == "part = 2 + 3\nresult = part * 1\n// Request record: " + request
        + "\n// Request record: Keep the addition equal.")
    let accepted = editor.sheet.text
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == original)
    #expect(editor.textView.selectedRange() == beforeSelection)
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == accepted)
    #expect(await transport.count() == 1)
  }

  @Test func aReferenceChoiceRechecksLocallyBeforeOneSourceTransaction() async throws {
    let original = request + "\n@1"
    let editor = try await editor(original)
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[0].id)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1",
      edits: [SuggestionEdit(target: "T1", replacement: "part = 2 + 3\nresult = part * 1")],
      bindings: [SuggestionBinding(symbol: "part", source: "L1")],
      literals: [
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle)),
        SuggestionLiteral(
          text: "3", evidence: try #require(evidence.first { $0.text == "three" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ], assumptions: [], summary: "Keep the result reference.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
    let transport = configure(editor, replies: [reply])
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    #expect(!session.canApply)
    let choice = try #require(session.availableChoices.first { $0.id.hasPrefix("reference_") })
    session.choose(choice.id, option: "line_2")
    await session.waitUntilIdle()
    #expect(session.canApply)
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text.hasSuffix("@2"))
    await editor.scheduler?.waitUntilIdle()
    #expect(
      editor.latestEvaluation?.lines.last?.result == .value(.number(.integer(IntegerValue(5)))))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == original)
    #expect(!editor.documentUndoManager.canUndo)
    #expect(await transport.count() == 1)
  }

  @Test func incompleteLineSelectionsAreNotSilentlyExpanded() async throws {
    let editor = try await editor(request + "\n" + request)
    let transport = configure(editor, replies: [])
    for range in [
      NSRange(location: 0, length: 3), NSRange(location: 0, length: request.utf16.count + 2),
    ] {
      editor.textView.setSelectedRange(range)
      editor.suggestionSession.prepare()
      await editor.suggestionSession.waitUntilIdle()
      #expect(!editor.suggestionSession.canSend)
    }
    #expect(await transport.count() == 0)
  }

  // MARK: - M1: the Ask surface

  /// The words in the bar are the words the model reads, and they go in one
  /// gesture: ⏎ prepares the scope and sends it.
  @Test func theWordsInTheBarAreTheWordsTheModelReads() async throws {
    let editor = try await editor(request)
    let transport = configure(editor, replies: [try await proposal(editor)])
    let session = editor.suggestionSession
    session.prepare(instruction: "make it monthly", autoSend: true)
    await session.waitUntilIdle()
    #expect(await transport.count() == 1)
    let body = String(decoding: try #require(session.requestBodies.first), as: UTF8.self)
    #expect(body.contains("make it monthly"))
    #expect(body.contains("reasoning_effort"))
    #expect(body.contains("\"medium\""))
    #expect(session.canApply)
    #expect(editor.sheet.text == request)
  }

  /// Off sends no effort word at all, on the Ask path as on the line path.
  @Test func anEffortOfOffSendsNoWordOnTheAskPath() async throws {
    let editor = try await editor(request)
    let transport = EditorSuggestionTransport([try await proposal(editor)])
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!,
        model: "synthetic", effort: .off))
    let session = editor.suggestionSession
    session.prepare(instruction: "add them", autoSend: true)
    await session.waitUntilIdle()
    #expect(await transport.count() == 1)
    let body = String(decoding: try #require(session.requestBodies.first), as: UTF8.self)
    #expect(!body.contains("reasoning_effort"))
  }

  /// One command, one bar, and the caret lands in the field so words can be typed.
  @Test func theAskCommandOpensTheBarWithTheCaretInTheField() async throws {
    let editor = try await editor(request)
    _ = configure(editor, replies: [try await proposal(editor)])
    let window = try #require(editor.view.window)
    window.makeKey()
    #expect(editor.openAskBar() == true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let field = try #require(
      fields(editor.view).first { $0.placeholderString?.contains("Ask Ganit") == true })
    // A focused text field owns a field editor, and the window's first responder
    // is that editor rather than the control.
    #expect(window.firstResponder === field.currentEditor())
    #expect(field.stringValue.isEmpty)
  }

  /// The chip is the passive half: detection without a request, on the caret's
  /// failing line and nowhere else, and it asks nothing of the provider until it
  /// is clicked and ⏎ follows.
  @Test func theChipWaitsOnTheCaretsFailingLineAndMakesNoRequest() async throws {
    // An unknown function, not a half-typed line: Ganit stays silent about a line
    // it reads as unfinished, and a chip on silence would nag.
    let editor = try await editor("nope(1)\n7")
    let transport = configure(editor, replies: [])
    let sheet = try #require(editor.textView as? SheetTextView)
    editor.view.layoutSubtreeIfNeeded()
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    #expect(sheet.askChipRect != nil)
    editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    #expect(sheet.askChipRect == nil)
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    sheet.askChipClicked()
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    #expect(await transport.count() == 0)
  }

  /// A provider that is not set up leaves the chip, the menu item and the
  /// selection action unavailable, so there is nothing to click into a failure.
  @Test func withoutAProviderNothingOffersAsk() async throws {
    let editor = try await editor("a = 1\nb = nope(2)")
    let sheet = try #require(editor.textView as? SheetTextView)
    editor.view.layoutSubtreeIfNeeded()
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    #expect(sheet.askChipRect == nil)
    let item = NSMenuItem(
      title: "", action: #selector(SheetCommands.askGanit(_:)), keyEquivalent: "")
    #expect(!sheet.validateUserInterfaceItem(item))
    select(editor, NSRange(location: 0, length: 17))
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let ask = try #require(buttons(editor.summaryBar).first { $0.title == "Ask Ganit…" })
    #expect(!editor.summaryBar.isHidden)
    #expect(ask.isHidden)
  }

  /// A multi-line selection grows the one trailing action the design allows.
  /// A multi-line selection grows the one trailing action the design allows.
  @Test func theSelectionBarOffersAskForAnAskableSelection() async throws {
    let editor = try await editor("a = 1\nb = nope(2)")
    _ = configure(editor, replies: [])
    select(editor, NSRange(location: 0, length: 17))
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let ask = try #require(buttons(editor.summaryBar).first { $0.title == "Ask Ganit…" })
    #expect(!editor.summaryBar.isHidden)
    #expect(!ask.isHidden)
    ask.performClick(nil)
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
  }

  /// Rule 4: the disclosure says what leaves the Mac, in words the reader can
  /// check against their own sheet, and it is readable before the send.
  @Test func theContextDisclosureNamesWhatLeavesTheMac() async throws {
    let editor = try await editor("a = 1\nb = a + 2")
    _ = configure(editor, replies: [])
    let session = editor.suggestionSession
    session.prepare(instruction: "round it to whole numbers")
    await session.waitUntilIdle()
    let body = try #require(session.preparedBody)
    let text = try #require(AskBar.contextSummary(for: body))
    #expect(text.contains("round it to whole numbers"))
    #expect(text.contains("a = 1"))
    #expect(text.contains("synthetic"))
    #expect(text.contains("medium"))
    #expect(!text.contains("apiKey"))
    #expect(!text.contains("fixture.invalid"))
    // The exact bytes remain available to anyone who would rather check the claim.
    #expect(AskBar.contextJSON(body).contains("\"reasoning_effort\""))
  }
}

private actor EditorSuggestionTransport: SuggestionTransport {
  private var replies: [Data?]
  private var requests = 0
  private var continuation: CheckedContinuation<Data, any Error>?
  private var ready: CheckedContinuation<Void, Never>?
  init(_ replies: [Data?]) { self.replies = replies }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    requests += 1
    ready?.resume()
    ready = nil
    if !replies.isEmpty, let reply = replies.removeFirst() { return reply }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func count() -> Int { requests }
  func waitForRequest() async {
    if requests > 0 { return }
    await withCheckedContinuation { ready = $0 }
  }
  func complete(_ reply: Data) {
    continuation?.resume(returning: reply)
    continuation = nil
  }
}
