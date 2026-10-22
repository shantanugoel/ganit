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
struct AskClarificationTests {
  private static var windows: [NSWindow] = []

  private func editor(_ source: String) async throws -> SheetEditorViewController {
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!)
    let editor = SheetEditorViewController(text: source, context: context)
    editor.documentUndoManager.groupsByEvent = false
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.contentViewController = editor
    window.layoutIfNeeded()
    Self.windows.append(window)
    await editor.scheduler?.waitUntilIdle()
    editor.textView.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
    return editor
  }

  /// The frozen wire contract allows at most three suggestions, and a question
  /// with none has to name the missing input instead.
  private func clarification(
    _ question: String, choices: [String] = ["Yes"], missingInput: String? = nil
  ) throws -> Data {
    var reply: [String: Any] = [
      "schemaVersion": 1, "kind": "clarify", "question": question, "choices": choices,
    ]
    if let missingInput { reply["missingInput"] = missingInput }
    return try JSONSerialization.data(withJSONObject: reply)
  }

  private func proposal(
    _ snapshot: AssistanceSnapshot, replacement: String,
    bindings: [(String, String)], literals: [(String, String)]
  ) throws -> Data {
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: replacement)],
      bindings: bindings.map { SuggestionBinding(symbol: $0.0, source: $0.1) },
      literals: try literals.map { claim in
        SuggestionLiteral(
          text: claim.0,
          evidence: try #require(
            evidence.first { $0.kind == "literal" && $0.text == claim.1 }?.handle,
            "Missing \(claim.1) in \(evidence.map(\.text))"))
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: [], summary: "Calculate with the supplied inputs.")
    #expect(try AssistanceCandidateChecker.check(candidate, against: snapshot).isApplicable)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
  }

  private func configure(_ editor: SheetEditorViewController, _ replies: [Data])
    -> ClarificationTransport
  {
    let transport = ClarificationTransport(replies)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "synthetic"))
    return transport
  }

  private func fields(_ view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
  }

  private func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
  }

  /// Engine numbers are exact rationals, and a 180-month payment has a
  /// numerator of several hundred digits. `Double(String)` turns those into
  /// infinities and `Decimal(string:)` refuses them, so a ratio is compared as
  /// two short mantissas and a power of ten.
  private func scaledDigits(_ digits: String) -> (mantissa: Double, exponent: Int)? {
    var body = Substring(digits)
    var sign = 1.0
    if body.hasPrefix("-") {
      sign = -1
      body = body.dropFirst()
    } else if body.hasPrefix("+") {
      body = body.dropFirst()
    }
    guard !body.isEmpty,
      body.allSatisfy({ $0 >= "0" && $0 <= "9" })
    else { return nil }
    let kept = String(body.prefix(17))
    guard var mantissa = Double(kept) else { return nil }
    mantissa *= sign
    return (mantissa, body.count - kept.count)
  }

  private func number(_ value: NumericValue) throws -> Double {
    switch value {
    case .integer(let value):
      let scaled = try #require(scaledDigits(value.canonicalDigits))
      return scaled.mantissa * pow(10, Double(scaled.exponent))
    case .rational(let value):
      let numerator = try #require(scaledDigits(value.numerator.canonicalDigits))
      let denominator = try #require(scaledDigits(value.denominator.canonicalDigits))
      return numerator.mantissa / denominator.mantissa
        * pow(10, Double(numerator.exponent - denominator.exponent))
    case .decimal(let value):
      let coefficient = try #require(scaledDigits(value.coefficient.canonicalDigits))
      return coefficient.mantissa * pow(10, Double(coefficient.exponent - value.scale))
    case .approximate(let value): return value.estimate
    }
  }

  @Test func theSameFieldAnswersTheTaxQuestionAndItsUserValueStaysOrdinarySource() async throws {
    let source = "food = 4200 INR\ndrinks = 1800 INR\nvenue = 3500 INR"
    let instruction = "Add tax to this."
    let editor = try await editor(source)
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
      .addingTaskNote(instruction).addingTaskNote("18%")
    let replacement = """
      food = 4200 INR
      drinks = 1800 INR
      venue = 3500 INR
      tax_rate = 18%
      tax = (food + drinks + venue) * tax_rate
      with_tax = food + drinks + venue + tax
      """
    let reply = try proposal(
      snapshot, replacement: replacement,
      bindings: [
        ("food", "L1"), ("drinks", "L2"), ("venue", "L3"), ("tax_rate", "L4"), ("tax", "L5"),
      ],
      literals: [
        ("4200 INR", "4200 INR"), ("1800 INR", "1800 INR"),
        ("3500 INR", "3500 INR"), ("18%", "18%"),
      ])
    let transport = configure(
      editor,
      [try clarification("What tax rate should I use?", choices: ["12%", "18%", "28%"]), reply])
    let session = editor.suggestionSession
    session.prepare(instruction: instruction, autoSend: true)
    await session.waitUntilIdle()
    let identity = session.continuousAsk
    #expect(session.clarificationCount == 1)
    #expect(session.originalWording == instruction)
    #expect(editor.sheet.text == source)
    #expect(session.preview == nil)
    let editable = fields(editor.view).filter(\.isEditable)
    #expect(editable.count == 1)
    let field = try #require(editable.first)
    #expect(field.placeholderString == "What tax rate should I use?")
    #expect(buttons(editor.view).contains { $0.title == "‹ " + instruction })
    field.stringValue = "18%"
    _ = field.target?.perform(field.action, with: field)
    await session.waitUntilIdle()
    #expect(session.continuousAsk == identity)
    #expect(await transport.count() == 2)
    #expect(session.canApply)
    #expect(session.preview?.requiresAssumptionApproval == false)
    let body = String(decoding: try #require(session.requestBodies.last), as: UTF8.self)
    #expect(body.contains(instruction))
    #expect(body.contains("18%"))
    guard case .money(let result) = session.preview?.result else {
      Issue.record("Expected a calculated dinner total")
      return
    }
    #expect(abs(try number(result.amount) - 11210) < 0.000001)
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text.contains("tax_rate = 18%"))
    #expect(!editor.sheet.text.contains("// AI:"))
    #expect(editor.sheet.text.contains("// Task record: 18%"))
    let rate = (editor.textView.string as NSString).range(of: "18%")
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText("5%", replacementRange: rate)
    editor.documentUndoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    guard case .value(.money(let revised)) = editor.latestEvaluation?.lines[5].result else {
      Issue.record("Expected the edited dinner total")
      return
    }
    #expect(abs(try number(revised.amount) - 9975) < 0.000001)
    #expect(await transport.count() == 2)
  }

  @Test func aThirdQuestionFailsTheContinuousAskAndEscapeCancelsTheWholeOperation() async throws {
    let source = "Add two and three."
    let editor = try await editor(source)
    let transport = configure(
      editor,
      [
        try clarification("Which rule?", choices: ["Addition"]),
        try clarification("Which order?", choices: ["Source order"]),
        try clarification("Which precision?", choices: ["Two decimals"]),
      ])
    let session = editor.suggestionSession
    session.prepare(instruction: "Calculate the sum.", autoSend: true)
    await session.waitUntilIdle()
    let identity = session.continuousAsk
    try #require(buttons(editor.view).first { $0.title == "Addition" }).performClick(nil)
    await session.waitUntilIdle()
    #expect(session.clarificationCount == 2)
    session.submitClarification("Source order", autoSend: true)
    await session.waitUntilIdle()
    #expect(session.continuousAsk == identity)
    #expect(session.clarificationCount == 2)
    #expect(session.state == .failed)
    if case .noUsefulAnswer = session.failure {
    } else {
      Issue.record("Expected the clarification limit failure")
    }
    #expect(session.clarification == nil)
    #expect(session.preview == nil)
    #expect(!session.canApply)
    #expect(editor.sheet.text == source)
    #expect(await transport.count() == 3)
    let sheet = try #require(editor.textView as? SheetTextView)
    sheet.complete(nil)
    #expect(!session.isVisible)
    session.prepare(instruction: "A new operation")
    await session.waitUntilIdle()
    #expect(session.continuousAsk != identity)
    #expect(session.clarificationCount == 0)
    #expect(await transport.count() == 3)
  }

  @Test func theOriginalWordingCrumbLetsTheUserRephraseWithoutSending() async throws {
    let editor = try await editor("Add two and three.")
    let transport = configure(
      editor, [try clarification("Which addition?", choices: ["Two and three"])])
    let session = editor.suggestionSession
    session.prepare(instruction: "Calculate the sum.", autoSend: true)
    await session.waitUntilIdle()
    try #require(buttons(editor.view).first { $0.title == "‹ Calculate the sum." }).performClick(
      nil)
    #expect(session.clarification == nil)
    let field = try #require(fields(editor.view).first { $0.isEditable })
    #expect(field.stringValue == "Calculate the sum.")
    #expect(await transport.count() == 1)
  }

  @Test func escapeInTheAnswerFieldCancelsTheWholeAsk() async throws {
    let source = "Add two and three."
    let editor = try await editor(source)
    let transport = configure(
      editor, [try clarification("Which addition?", choices: ["Two and three"])])
    editor.suggestionSession.prepare(instruction: "Calculate the sum.", autoSend: true)
    await editor.suggestionSession.waitUntilIdle()
    let bar = try #require(editor.view.subviews.compactMap { $0 as? AskBar }.first)
    let field = try #require(fields(bar).first { $0.isEditable })
    #expect(
      bar.control(
        field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!editor.suggestionSession.isVisible)
    #expect(editor.suggestionSession.clarification == nil)
    #expect(editor.sheet.text == source)
    #expect(await transport.count() == 1)
  }

  @Test func anAnswerThatNamesMoreSourceNeedsAnotherContextReview() async throws {
    let editor = try await editor("secret = 9876\nAdd two and three.")
    editor.textView.setSelectedRange(NSRange(location: "secret = 9876\n".utf16.count, length: 0))
    let transport = configure(
      editor, [try clarification("Which other amount?", choices: ["The secret amount"])])
    let session = editor.suggestionSession
    session.prepare(instruction: "Calculate the sum.", autoSend: true)
    await session.waitUntilIdle()
    #expect(
      !String(decoding: try #require(session.requestBodies.first), as: UTF8.self).contains("9876"))
    session.submitClarification("Use secret.", autoSend: true)
    await session.waitUntilIdle()
    #expect(await transport.count() == 1)
    #expect(session.canSend)
    #expect(session.message.contains("adds source records"))
    #expect(String(decoding: try #require(session.preparedBody), as: UTF8.self).contains("9876"))
  }

  @Test func theThreeProseInputsProduceNativeLoanComparisons() async throws {
    let source =
      "The apartment costs 1.8 crore. I can put down 50 lakh. The loan is around 8%.\nI would otherwise pay 65k a month in rent.\nCompare 10, 15 and 20 year loans."
    let instruction = "Compare payments with a nominal annual rate and 12 payments per year."
    let editor = try await editor(source)
    let snapshot = try await editor.suggestionSnapshot(targets: editor.sheet.lines.map(\.id))
      .addingTaskNote(instruction)
    let replacement = """
      price = 1.8 * 10000000
      down = 50 * 100000
      annual_rate = 8%
      rent = 65 * 1000
      emi_10 = pmt(price - down, annual_rate / 12, 10 * 12)
      emi_15 = pmt(price - down, annual_rate / 12, 15 * 12)
      emi_20 = pmt(price - down, annual_rate / 12, 20 * 12)
      """
    let reply = try proposal(
      snapshot, replacement: replacement,
      bindings: [("price", "L1"), ("down", "L2"), ("annual_rate", "L3")],
      literals: [
        ("1.8", "1.8"), ("10000000", "crore"), ("50", "50"), ("100000", "lakh"),
        ("8%", "8%"), ("65", "65"), ("1000", "k"), ("10", "10"), ("15", "15"), ("20", "20"),
        ("12", "12"),
      ])
    let transport = configure(editor, [reply])
    let session = editor.suggestionSession
    session.prepare(instruction: instruction, autoSend: true)
    await session.waitUntilIdle()
    #expect(session.canApply)
    let preview = try #require(session.preview)
    let rate = 0.08 / 12
    for (index, years) in [10, 15, 20].enumerated() {
      guard case .value(.number(let result)) = preview.evaluation.lines[index + 4].result else {
        Issue.record("Expected a native payment")
        continue
      }
      let expected = 13_000_000 * rate / (1 - pow(1 + rate, -Double(years * 12)))
      let got = try number(result)
      #expect(
        abs(got - expected) <= max(0.000001, abs(expected) * 0.000000001),
        "index \(index) got \(got) expected \(expected)")
    }
    session.apply()
    await session.waitUntilIdle()
    #expect(editor.sheet.text.contains(replacement))
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == source)
    #expect(await transport.count() == 1)
  }
}

private actor ClarificationTransport: SuggestionTransport {
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
