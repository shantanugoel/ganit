import AppKit
import Foundation
import GanitAssistance
import GanitData
import GanitEngine
import GanitFormatting
import GanitSuggestionProtocol
import ScreenCaptureKit
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

  @Test func theOffSettingBlocksEveryAskEntryAndClearsAnOpenJob() async throws {
    let editor = try await editor("10 kg of water in ml")
    let transport = configure(editor, replies: [nil])
    let view = try #require(editor.textView as? SheetTextView)
    editor.suggestionSession.prepare()
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    let configuration = try #require(editor.suggestionConfiguration)
    var settings = configuration.settings
    settings.isEnabled = false
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: configuration.coordinator, settings: settings)
    #expect(!editor.suggestionSession.isVisible)
    #expect(!editor.openAskBar())
    #expect(!view.canAskGanit())
    #expect(view.askChipRect == nil)
    #expect(
      !view.validateUserInterfaceItem(
        NSMenuItem(
          title: "Ask Ganit…", action: #selector(SheetCommands.askGanit(_:)), keyEquivalent: "")))
    view.onAskGanit()
    editor.summaryBar.onAsk?()
    editor.suggestionSession.prepare(instruction: "why?", autoSend: true)
    editor.suggestionSession.send()
    await editor.suggestionSession.waitUntilIdle()
    #expect(!editor.suggestionSession.isVisible)
    #expect(await transport.count() == 0)
    #expect(view.interpretationPopover?.isShown != true)
  }

  @Test func assumptionAndDependencyMarksAreAccessibleButtons() async throws {
    let editor = try await editor(
      "density = 1 kg/L // AI: density of water · synthetic · 2026-10-22\n10 kg / density")
    _ = configure(editor, replies: [])
    let view = try #require(editor.textView as? SheetTextView)
    let elements = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    let origin = try #require(
      elements.first { $0.accessibilityLabel()?.contains("AI assumption. Show") == true })
    let dependency = try #require(
      elements.first { $0.accessibilityLabel()?.contains("uses an AI assumption") == true })
    #expect(origin.accessibilityRole() == .button)
    #expect(dependency.accessibilityRole() == .button)
    var inspected: [LineID] = []
    view.onInspectAssumption = { line, _ in inspected.append(line) }
    #expect(origin.accessibilityPerformPress())
    #expect(dependency.accessibilityPerformPress())
    #expect(inspected == editor.sheet.lines.map(\.id))
    select(editor, NSRange(location: 0, length: 0))
    #expect(view.accessibilityCustomActions()?.contains { $0.name == "Show AI assumption" } == true)
    select(editor, NSRange(location: editor.sheet.text.utf16.count, length: 0))
    #expect(
      view.accessibilityCustomActions()?.contains { $0.name == "Show AI assumption source" } == true
    )
    editor.markAIDerivedAnswers = false
    #expect(
      view.accessibilityCustomActions()?.contains { $0.name == "Show AI assumption source" }
        == false)

  }

  @Test func markedLinesAreReachableWithoutAPointerAndAimableWithoutPrecision() async throws {
    let editor = try await editor(
      "total = 300\ndensity = 1 kg/L // AI: density of water · synthetic · 2026-10-22\n10 kg / density"
    )
    _ = configure(editor, replies: [])
    let view = try #require(editor.textView as? SheetTextView)
    // The caret sits on an ordinary line: no mark is hovered or selected, yet
    // each one still has an action a keyboard or VoiceOver user can reach.
    select(editor, NSRange(location: 0, length: 0))
    let names = view.accessibilityCustomActions()?.map(\.name) ?? []
    #expect(names.contains { $0.hasPrefix("Show AI assumption") })
    #expect(names.contains { $0.hasPrefix("Show AI assumption source") })

    // Pressing the mark itself still opens that line's card.
    var inspected: [LineID] = []
    view.onInspectAssumption = { line, _ in inspected.append(line) }
    let density = editor.sheet.lines[1].id
    let reader = editor.sheet.lines[2].id
    for line in [density, reader] {
      let badge = try #require(view.assumptionBadgeRect(for: line))
      #expect(view.assumptionBadgeHit(at: NSPoint(x: badge.midX, y: badge.midY))?.line == line)
      let justPastTheMark = NSPoint(x: badge.maxX + 2, y: badge.midY)
      #expect(
        view.assumptionBadgeHit(at: justPastTheMark)?.line == line,
        "A point two points past the mark no longer opens the card")
      if let hit = view.assumptionBadgeHit(at: justPastTheMark) {
        view.onInspectAssumption(hit.line, hit.rect)
      }
    }
    #expect(inspected == [density, reader])
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

  @Test func documentEditsInvalidateCachedProposalsEvenAfterUndo() async throws {
    let editor = try await editor(request)
    let reply = try await proposal(editor)
    let transport = configure(editor, replies: [reply, reply])
    let session = editor.suggestionSession
    for _ in 0..<2 {
      session.prepare(autoSend: true)
      await session.waitUntilIdle()
      #expect(session.canApply)
      session.dismiss()
    }
    #expect(await transport.count() == 1)
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(
      "!", replacementRange: NSRange(location: request.utf16.count, length: 0))
    editor.documentUndoManager.endUndoGrouping()
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == request)
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(await transport.count() == 2)
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
    #expect(editor.view.window?.firstResponder === editor.textView)
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

  @Test func decliningAProposedLineKeepsItsSourceAndAppliesTheRestAsOneUndo() async throws {
    let original = "Add two and three.\nAdd four and five."
    let editor = try await editor(original)
    select(editor, NSRange(location: 0, length: original.utf16.count))
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3\n4 + 5")],
      bindings: [],
      literals: try zip(["2", "3", "4", "5"], ["two", "three", "four", "five"]).map { value, word in
        SuggestionLiteral(
          text: value,
          evidence: try #require(evidence.first { $0.text == word && $0.kind == "literal" }?.handle)
        )
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Add each pair.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    let reply = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
    let transport = configure(editor, replies: [reply])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    session.includeLine(0, included: false)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement == "Add two and three.\n4 + 5")
    #expect(editor.sheet.text == original)
    session.includeLine(1, included: false)
    await session.waitUntilIdle()
    #expect(!session.canApply)
    #expect(session.proposalLines.count == 2)
    session.includeLine(1, included: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    session.apply()
    await session.waitUntilIdle()
    #expect(session.state == .applied)
    #expect(editor.sheet.text.hasPrefix("Add two and three.\n4 + 5\n"))
    #expect(editor.documentUndoManager.undoActionName == "Apply AI change")
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == original)
    #expect(await transport.count() == 1)
  }

  @Test func decliningARequiredDeclarationBlocksApplyAndCanBeRestored() async throws {
    let editor = try await editor(request)
    let base = try await proposal(editor)
    var reply = try #require(JSONSerialization.jsonObject(with: base) as? [String: Any])
    var candidate = try #require((reply["candidates"] as? [[String: Any]])?.first)
    candidate["edits"] = [["target": "T1", "replacement": "subtotal = 2 + 3\nsubtotal + 2"]]
    candidate["bindings"] = [["symbol": "subtotal", "source": "L1"]]
    reply["candidates"] = [candidate]
    let transport = configure(editor, replies: [try JSONSerialization.data(withJSONObject: reply)])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    session.includeLine(0, included: false)
    await session.waitUntilIdle()
    #expect(!session.canApply)
    #expect(session.preview == nil)
    #expect(session.proposalLines.count == 2)
    session.apply()
    #expect(editor.sheet.text == request)
    session.includeLine(0, included: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(await transport.count() == 1)
  }

  @Test(arguments: ["\n", "\r\n"])
  func aDeletionCanBeDeclinedAndRetainsItsNumericEvidence(_ newline: String) async throws {
    let original = request + newline + "8"
    let editor = try await editor(original)
    select(editor, NSRange(location: 0, length: original.utf16.count))
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3")], bindings: [],
      literals: try zip(["2", "3"], ["two", "three"]).map { value, word in
        SuggestionLiteral(
          text: value,
          evidence: try #require(evidence.first { $0.text == word && $0.kind == "literal" }?.handle)
        )
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Add the pair.")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    _ = configure(
      editor,
      replies: [
        try JSONSerialization.data(withJSONObject: [
          "schemaVersion": 1, "kind": "proposal", "candidates": [object],
        ])
      ])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.proposalLines == ["2 + 3", "Remove: 8"])
    session.includeLine(1, included: false)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement == "2 + 3" + newline + "8")
    session.includeLine(0, included: false)
    await session.waitUntilIdle()
    #expect(!session.canApply)
    session.includeLine(1, included: true)
    await session.waitUntilIdle()
    #expect(!session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement != original)
    session.includeLine(0, included: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    #expect(session.preview?.candidate.edits[0].replacement == "2 + 3")
  }

  @Test func aRetainedSourceRowCanMoveWhenAnEarlierRowIsRemoved() async throws {
    let original = request + "\n8\nKeep this."
    let editor = try await editor(original)
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3")], bindings: [],
      literals: try zip(["2", "3"], ["two", "three"]).map { value, word in
        SuggestionLiteral(
          text: value,
          evidence: try #require(evidence.first { $0.text == word && $0.kind == "literal" }?.handle)
        )
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Add the pair.")
    let revised = try AssistanceCandidateChecker.selectingLines(
      candidate, against: snapshot, omitted: [2], choices: [:])
    #expect(revised.edits[0].replacement == "2 + 3\nKeep this.")
    let checked = try AssistanceCandidateChecker.check(revised, against: snapshot)
    #expect(checked.isApplicable)
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(revised, against: snapshot)
    #expect(edit.sourceAfter.hasPrefix("2 + 3\nKeep this.\n"))
  }

  @Test func anEarlierProposedFailureIsRejectedEvenWhenTheLastLineCalculates() async throws {
    let editor = try await editor("Add two and three, with zero.")
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[0].id)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 / 0\n2 + 3")], bindings: [],
      literals: try zip(["2", "3", "0"], ["two", "three", "zero"]).map { value, word in
        SuggestionLiteral(
          text: value,
          evidence: try #require(evidence.first { $0.text == word && $0.kind == "literal" }?.handle)
        )
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Calculate both lines.")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
  }

  @Test func quickGanitDoesNotHaveAnAskProvider() async throws {
    let editor = try await editor(request, surface: .quickGanit)
    let view = try #require(editor.textView as? SheetTextView)
    #expect(editor.suggestionConfiguration == nil)
    #expect(!editor.openAskBar())
    #expect(!view.canAskGanit())
    #expect(view.askChipRect == nil)
    editor.suggestionSession.prepare(autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    #expect(!editor.suggestionSession.isVisible)
    #expect(editor.sheet.text == request)
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

  /// Section 2's second rule: an assumption the model invented — no declared
  /// value, no basis, nothing Ganit can check — is not a source change at all.
  /// Ganit refuses the reply, asks for it to be fixed twice, then fails
  /// honestly. The reader is never offered a checkbox for a number that cannot
  /// be verified, and no comment of Ganit's makes one look sanctioned.
  @Test func aWorkingAssumptionTheModelInventedIsRefusedNotApproved() async throws {
    let editor = try await editor(request)
    let reply = try await proposal(editor, assumption: true)
    let transport = configure(editor, replies: [reply, reply, reply])
    let session = editor.suggestionSession
    session.prepare()
    await session.waitUntilIdle()
    session.send()
    await session.waitUntilIdle()
    #expect(session.state == .failed)
    #expect(session.failure != nil)
    #expect(!session.canApply)
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    func titles(_ view: NSView) -> [String] {
      (view as? NSButton).map { [$0.title] } ?? view.subviews.flatMap(titles)
    }
    #expect(
      !titles(bar).contains("Use equal weights."),
      "An unverifiable assumption is never offered for approval")
    #expect(editor.sheet.text == request)
    #expect(!editor.sheet.text.contains("Approved assumption"))
    #expect(!editor.sheet.text.contains("// AI:"))
    // It asked once to have the reply fixed, got the same reply back, and
    // stopped rather than looping at the provider (plan §5).
    #expect(await transport.count() == 2)
    #expect(session.message.localizedCaseInsensitiveContains("assumption"))
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
  @Test func aNewAskClearsThePreviousInstructionAfterApplyAndSourceReplacement() async throws {
    let editor = try await editor(request)
    let transport = configure(editor, replies: [try await proposal(editor)])
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    editor.openAskBar()
    await editor.suggestionSession.waitUntilIdle()
    let field = try #require(
      fields(editor.view).first { $0.accessibilityLabel() == "What to ask Ganit" })
    field.stringValue = "Use the numbers in this line."
    editor.suggestionSession.prepare(instruction: field.stringValue, autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    editor.suggestionSession.apply()
    await editor.suggestionSession.waitUntilIdle()
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText(
      "What is the capital of France?",
      replacementRange: NSRange(location: 0, length: editor.sheet.text.utf16.count))
    editor.documentUndoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    editor.openAskBar()
    await editor.suggestionSession.waitUntilIdle()
    #expect(field.stringValue.isEmpty)
    #expect(editor.suggestionSession.instruction.isEmpty)
    #expect(await transport.count() == 1)
  }

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
    let editor = try await editor("price = 12\ntotal = nope(3)\ntax = 1")
    let transport = configure(editor, replies: [])
    let sheet = try #require(editor.textView as? SheetTextView)
    editor.view.layoutSubtreeIfNeeded()
    select(editor, NSRange(location: 11, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    let chip = try #require(sheet.askChipRect)
    // The chip belongs in the source, beside what the line says — never inside
    // the answer column, where it would hide under the failure message.
    if let separator = sheet.answerSeparatorX {
      #expect(chip.maxX <= separator)
    }
    select(editor, NSRange(location: 27, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    #expect(sheet.askChipRect == nil)
    select(editor, NSRange(location: 11, length: 0))
    editor.view.layoutSubtreeIfNeeded()
    let accessibleChip = try #require(
      (sheet.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        .first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Ask Ganit…" })
    #expect(accessibleChip.accessibilityPerformPress())
    await editor.suggestionSession.waitUntilIdle()
    #expect(editor.suggestionSession.isVisible)
    #expect(await transport.count() == 0)
  }

  @Test func theChipFollowsTheCaretInsideAndAtTheEndOfAUnicodeLine() async throws {
    let prefix = "// 🧮 café\n"
    let failing = "total = nope(3) // café 🧮"
    let editor = try await editor(prefix + failing)
    let transport = configure(editor, replies: [])
    let sheet = try #require(editor.textView as? SheetTextView)
    for offset in [prefix.utf16.count, prefix.utf16.count + 10, (prefix + failing).utf16.count] {
      select(editor, NSRange(location: offset, length: 0))
      #expect(sheet.askChipRect != nil)
    }
    select(editor, NSRange(location: 4, length: 0))
    #expect(sheet.askChipRect == nil)
    #expect(await transport.count() == 0)
  }

  @Test func theChipDoesNotOfferAnIncompleteExpressionOnTheCaretLine() async throws {
    let editor = try await editor("price = 12\ntotal = 3 +")
    let transport = configure(editor, replies: [])
    select(editor, NSRange(location: "price = 12\ntotal = 3 +".utf16.count, length: 0))
    let sheet = try #require(editor.textView as? SheetTextView)
    #expect(sheet.askChipRect == nil)
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

  @Test func openingContextPreparesTypedWordsWithoutSendingAndReturnUsesThoseBytes() async throws {
    let editor = try await editor(request)
    let reply = Data(
      #"{"schemaVersion":1,"kind":"unsupported","reason":"No supported edit."}"#.utf8)
    let transport = configure(editor, replies: [reply])
    editor.openAskBar()
    let session = editor.suggestionSession
    await session.waitUntilIdle()
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let field = try #require(
      fields(bar).first { $0.accessibilityLabel() == "What to ask Ganit" })
    field.stringValue = "  Use these supplied numbers.  "
    let context = try #require(buttons(bar).first { $0.title == "Context ▸" })
    context.performClick(nil)
    await session.waitUntilIdle()
    let body = try #require(session.preparedBody)
    #expect(AskBar.contextSummary(for: body)?.contains("Use these supplied numbers.") == true)
    #expect(await transport.count() == 0)
    #expect(editor.sheet.text == request)
    #expect(
      bar.control(
        field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    await session.waitUntilIdle()
    #expect(await transport.count() == 1)
    #expect(session.requestBodies.first == body)
  }

  @Test func contextCanReviewATypedClarificationBeforeTheNextRequest() async throws {
    let editor = try await editor(request)
    let question = Data(
      #"{"schemaVersion":1,"kind":"clarify","question":"How should Ganit combine them?","choices":["Add them","Multiply them"]}"#
        .utf8)
    let failure = Data(
      #"{"schemaVersion":1,"kind":"unsupported","reason":"No supported edit."}"#.utf8)
    let transport = configure(editor, replies: [question, failure])
    let session = editor.suggestionSession
    session.prepare(autoSend: true)
    await session.waitUntilIdle()
    #expect(session.clarification != nil)
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let field = try #require(fields(bar).first { $0.isEditable })
    field.stringValue = "Multiply them."
    try #require(buttons(bar).first { $0.title == "Context ▸" }).performClick(nil)
    await session.waitUntilIdle()
    let body = try #require(session.preparedBody)
    #expect(AskBar.contextSummary(for: body)?.contains("Multiply them.") == true)
    #expect(await transport.count() == 1)
    #expect(session.clarificationCount == 1)
    #expect(
      bar.control(
        field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    await session.waitUntilIdle()
    #expect(await transport.count() == 2)
    #expect(session.requestBodies.last == body)
  }

  @Test func theBarBackgroundStaysInsideItsBounds() async throws {
    let editor = try await editor("price = 12\ntotal = nope(3)")
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    bar.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 180,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    NSColor.magenta.setFill()
    NSRect(x: 0, y: 0, width: 400, height: 180).fill()
    let transform = NSAffineTransform()
    transform.translateX(by: 40, yBy: 40)
    transform.concat()
    // AppKit can pass a dirty rectangle that extends into the sheet above.
    bar.draw(NSRect(x: -40, y: -40, width: 400, height: 180))
    graphics.flushGraphics()
    for point in [(20, 90), (380, 90), (200, 20), (200, 160)] {
      let color = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
      #expect(color.redComponent > 0.95)
      #expect(color.greenComponent < 0.05)
      #expect(color.blueComponent > 0.95)
    }
    let inside = try #require(bitmap.colorAt(x: 200, y: 90)?.usingColorSpace(.deviceRGB))
    #expect(inside.greenComponent > 0.05, "the bar must still draw its own background")
  }

  // This gate requires a desktop session and screen capture permission.
  // Run with GANIT_WINDOW_CAPTURE_TESTS=1. Do not substitute cacheDisplay:
  // it draws each view again and cannot detect a sibling that covers the sheet.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["GANIT_WINDOW_CAPTURE_TESTS"] == "1"))
  func theSourceStaysInkWhileTheBarIsOpen() async throws {
    let editor = try await editor("price = 12\ntotal = nope(3)")
    _ = configure(editor, replies: [])
    let window = try #require(editor.view.window)
    window.setContentSize(NSSize(width: 720, height: 620))
    window.center()
    window.tabbingMode = .disallowed
    defer { window.orderOut(nil) }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: appearance)
      window.makeKeyAndOrderFront(nil)
      for _ in 0..<3 {
        let closed = try await compositedSourceInk(editor)
        #expect(editor.openAskBar() == true)
        await editor.suggestionSession.waitUntilIdle()
        let opened = try await compositedSourceInk(editor)
        #expect(editor.suggestionSession.isVisible)
        #expect(closed > 20, "the closed sheet must have visible source text")
        #expect(opened >= closed * 3 / 4, "the open bar covered the source text")
        editor.stopSuggestions()
        let dismissed = try await compositedSourceInk(editor)
        #expect(dismissed >= closed * 3 / 4)
      }
    }
  }

  /// A review surface must not hide what is under review. Driving the built app
  /// found the source text vanishing while the bar is open, so the sheet has to
  /// stay drawable and inside its own scroll view the whole time.
  @Test func theSheetStillDrawsWhileTheBarIsOpen() async throws {
    let editor = try await editor("price = 12\ntotal = nope(3)")
    _ = configure(editor, replies: [])
    let sheet = editor.textView
    let text = sheet.string
    #expect(editor.openAskBar() == true)
    await editor.suggestionSession.waitUntilIdle()
    editor.view.layoutSubtreeIfNeeded()
    #expect(editor.suggestionSession.isVisible)
    #expect(sheet.isHidden == false)
    #expect(sheet.alphaValue == 1)
    #expect(sheet.isSelectable == true)
    #expect(sheet.textColor != nil)
    #expect(sheet.string == text)
    #expect(sheet.enclosingScrollView?.isHidden == false)
    #expect(sheet.frame.height > 8)
    for sub in sheet.subviews where String(describing: type(of: sub)) != "_NSTextSelectionView" {
      #expect(sub.isHidden == false, "hidden: \(String(describing: type(of: sub)))")
    }
    // The document has to sit inside the clip view: if a layout pass leaves it
    // outside, the source disappears while the answer overlay keeps drawing.
    if let clip = sheet.enclosingScrollView?.contentView {
      let visible = sheet.convert(sheet.bounds, to: clip)
      #expect(!visible.intersection(clip.bounds).isEmpty)
      #expect(clip.bounds.minY == clip.documentView?.frame.minY)
    }
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

/// Count source pixels in the window server image. Never redraw the view here.
@MainActor
private func compositedSourceInk(_ editor: SheetEditorViewController) async throws -> Int {
  let window = try #require(editor.view.window)
  #expect(CGPreflightScreenCaptureAccess(), "screen capture permission is required for this gate")
  editor.view.layoutSubtreeIfNeeded()
  editor.textView.scroll(.zero)
  window.displayIfNeeded()
  // Let the window server finish the frame before capture.
  try await Task.sleep(for: .milliseconds(250))
  let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: true)
  let target = try #require(
    content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
  let filter = SCContentFilter(desktopIndependentWindow: target)
  let configuration = SCStreamConfiguration()
  configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
  configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
  configuration.showsCursor = false
  if #available(macOS 14.2, *) { configuration.ignoreShadowsSingleWindow = true }
  let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: configuration)
  let bitmap = NSBitmapImageRep(cgImage: image)
  let sheet = editor.textView
  let source = sheet.convert(
    NSRect(origin: sheet.textContainerOrigin, size: NSSize(width: 180, height: 50)), to: nil)
  let sx = CGFloat(image.width) / window.frame.width
  let sy = CGFloat(image.height) / window.frame.height
  let x0 = max(0, Int(source.minX * sx))
  let x1 = min(image.width, Int(source.maxX * sx))
  let y0 = max(0, Int((window.frame.height - source.maxY) * sy))
  let y1 = min(image.height, Int((window.frame.height - source.minY) * sy))
  #expect(x1 > x0 && y1 > y0, "the source capture region must be inside the window")
  let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  var count = 0
  for y in y0..<y1 {
    for x in x0..<x1 {
      let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericGray))
      if dark ? color.whiteComponent > 0.7 : color.whiteComponent < 0.3 { count += 1 }
    }
  }
  return count
}
