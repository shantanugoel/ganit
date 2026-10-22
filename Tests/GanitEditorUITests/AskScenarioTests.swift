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
struct AskScenarioTests {
  private static var windows: [NSWindow] = []

  private func editor(_ source: String) async throws -> SheetEditorViewController {
    let rates = try CurrencyRates(
      unitsPerEuro: ["USD": "1", "INR": "90"], observationDate: "1970-01-01",
      retrievedAt: Date(timeIntervalSince1970: 0))
    let context = try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
      angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(identifier: "UTC")!, currencyRates: rates)
    let editor = SheetEditorViewController(text: source, context: context, display: .standard)
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

  private func reply(
    snapshot: AssistanceSnapshot, replacement: String, bindings: [(String, String)],
    literals: [(String, String)]
  ) throws -> Data {
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "scenario", edits: [SuggestionEdit(target: "T1", replacement: replacement)],
      bindings: bindings.map { SuggestionBinding(symbol: $0.0, source: $0.1) },
      literals: try literals.map { literal in
        SuggestionLiteral(
          text: literal.0,
          evidence: try #require(
            evidence.first { $0.kind == "literal" && $0.text == literal.1 }?.handle,
            "Missing evidence for \(literal.1): \(evidence.map(\.text))"))
      },
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ], assumptions: [], summary: "Calculate the supplied request.")
    #expect(try AssistanceCandidateChecker.check(candidate, against: snapshot).isApplicable)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "proposal", "candidates": [object],
    ])
  }

  private func configure(_ editor: SheetEditorViewController, reply: Data) -> ScenarioTransport {
    let transport = ScenarioTransport(reply: reply)
    editor.suggestionConfiguration = SheetSuggestionConfiguration(
      coordinator: SuggestionCoordinator(transport: transport),
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "https://fixture.invalid/v1")!, model: "scenario"))
    return transport
  }

  private func amount(_ result: CalculationResult?, currency: String) throws -> Double {
    guard case .value(.money(let money)) = result else {
      Issue.record("Expected a calculated amount in \(currency), got \(String(describing: result))")
      throw ScenarioFailure.missingMoney
    }
    #expect(money.currency == currency)
    switch money.amount {
    case .integer(let value): return try #require(Double(value.canonicalDigits))
    case .rational(let value):
      return try #require(Double(value.numerator.canonicalDigits))
        / #require(Double(value.denominator.canonicalDigits))
    case .decimal(let value):
      return try #require(Double(value.coefficient.canonicalDigits)) / pow(10, Double(value.scale))
    case .approximate(let value): return value.estimate
    }
  }

  @Test func loanProseProducesNativePaymentsAndOneUndoRestoresBytesAndCaret() async throws {
    let prose = "I’m borrowing ₹25 lakh for 5 years at 8.2%. What will I pay monthly?"
    let original = "# Home loan\n\n" + prose
    let instruction = "Use a nominal annual rate and 12 payments per year."
    let editor = try await editor(original)
    let selection = NSRange(location: "# Home loan\n\n".utf16.count, length: 0)
    editor.textView.setSelectedRange(selection)
    let snapshot = try await editor.suggestionSnapshot(target: editor.sheet.lines[2].id)
      .addingTaskNote(instruction)
    let replacement = """
      principal = 2500000 INR
      annual_rate = 8.2%
      years = 5
      monthly = pmt(principal, annual_rate / 12, years * 12)
      total_paid = monthly * years * 12
      interest = total_paid - principal
      """
    let transport = configure(
      editor,
      reply: try reply(
        snapshot: snapshot, replacement: replacement,
        bindings: [
          ("principal", "L1"), ("annual_rate", "L2"), ("years", "L3"),
          ("monthly", "L4"), ("total_paid", "L5"),
        ],
        literals: [("2500000 INR", "₹25 lakh"), ("8.2%", "8.2%"), ("5", "5"), ("12", "12")]))
    let session = editor.suggestionSession
    session.prepare(instruction: instruction)
    await session.waitUntilIdle()
    #expect(await transport.count() == 0)
    session.send()
    await session.waitUntilIdle()
    #expect(session.canApply, "\(session.state)")
    #expect(Array(editor.sheet.text.utf8) == Array(original.utf8))
    let preview = try #require(session.preview)
    let rate = 0.082 / 12
    let monthly = 2_500_000 * rate / (1 - pow(1 + rate, -60))
    #expect(
      abs(try amount(preview.evaluation.lines[5].result, currency: "INR") - monthly) < 0.000001)
    #expect(
      abs(try amount(preview.evaluation.lines[6].result, currency: "INR") - monthly * 60) < 0.000001
    )
    #expect(
      abs(
        try amount(preview.evaluation.lines[7].result, currency: "INR") - (monthly * 60 - 2_500_000)
      ) < 0.000001)
    session.apply()
    await session.waitUntilIdle()
    await editor.scheduler?.waitUntilIdle()
    #expect(session.state == .applied)
    #expect(editor.sheet.text.contains(replacement))
    #expect(editor.documentUndoManager.undoActionName == "Apply AI change")
    #expect(
      abs(try amount(editor.latestEvaluation?.lines[5].result, currency: "INR") - monthly)
        < 0.000001)
    let accepted = editor.sheet.text
    editor.documentUndoManager.undo()
    #expect(Array(editor.sheet.text.utf8) == Array(original.utf8))
    #expect(editor.textView.selectedRange() == selection)
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == accepted)
    let principal = (editor.textView.string as NSString).range(of: "2500000")
    editor.documentUndoManager.beginUndoGrouping()
    editor.textView.insertText("3000000", replacementRange: principal)
    editor.documentUndoManager.endUndoGrouping()
    await editor.scheduler?.waitUntilIdle()
    #expect(
      abs(try amount(editor.latestEvaluation?.lines[5].result, currency: "INR") - monthly * 1.2)
        < 0.000001)
    #expect(await transport.count() == 1)
  }

  @Test func tripSelectionUsesNativeCurrencyAndOneUndoRestoresBytesAndSelection() async throws {
    let prefix = "# Trip to Goa\n\n"
    let selected =
      "hotel = 185 USD\nnights = 6\nflight = 680 USD\n\ntrip_total = hotel * nights + flight"
    let original = prefix + selected
    let instruction = "Compare this trip in USD and INR, and add a 12% contingency."
    let editor = try await editor(original)
    let selection = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
    editor.textView.setSelectedRange(selection)
    let snapshot = try await editor.suggestionSnapshot(
      targets: Array(editor.sheet.lines[2...]).map(\.id)
    )
    .addingTaskNote(instruction)
    let replacement = """
      hotel = 185 USD
      nights = 6
      flight = 680 USD

      trip_total = hotel * nights + flight
      contingency = trip_total * 12%
      trip_usd = trip_total + contingency
      trip_inr = trip_usd in INR
      """
    let transport = configure(
      editor,
      reply: try reply(
        snapshot: snapshot, replacement: replacement,
        bindings: [
          ("hotel", "L1"), ("nights", "L2"), ("flight", "L3"),
          ("trip_total", "L5"), ("contingency", "L6"), ("trip_usd", "L7"),
        ],
        literals: [("185 USD", "185 USD"), ("6", "6"), ("680 USD", "680 USD"), ("12%", "12%")]))
    let session = editor.suggestionSession
    session.prepare(instruction: instruction)
    await session.waitUntilIdle()
    #expect(await transport.count() == 0)
    session.send()
    await session.waitUntilIdle()
    #expect(session.canApply, "\(session.state)")
    #expect(editor.sheet.text == original)
    let preview = try #require(session.preview)
    #expect(abs(try amount(preview.evaluation.lines[6].result, currency: "USD") - 1790) < 0.000001)
    #expect(abs(try amount(preview.evaluation.lines[7].result, currency: "USD") - 214.8) < 0.000001)
    #expect(
      abs(try amount(preview.evaluation.lines[8].result, currency: "USD") - 2004.8) < 0.000001)
    #expect(
      abs(try amount(preview.evaluation.lines[9].result, currency: "INR") - 180432) < 0.000001)
    #expect(preview.rateUses == [.crossReference])
    session.apply()
    await session.waitUntilIdle()
    await editor.scheduler?.waitUntilIdle()
    #expect(session.state == .applied)
    #expect(editor.sheet.text.contains(replacement))
    #expect(editor.documentUndoManager.undoActionName == "Apply AI change")
    #expect(
      abs(try amount(editor.latestEvaluation?.lines[9].result, currency: "INR") - 180432) < 0.000001
    )
    let accepted = editor.sheet.text
    editor.documentUndoManager.undo()
    #expect(Array(editor.sheet.text.utf8) == Array(original.utf8))
    #expect(editor.textView.selectedRange() == selection)
    #expect(!editor.documentUndoManager.canUndo)
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == accepted)
    let reopened = try await self.editor(accepted)
    #expect(
      abs(try amount(reopened.latestEvaluation?.lines[9].result, currency: "INR") - 180432)
        < 0.000001)
    #expect(await transport.count() == 1)
  }
}

private enum ScenarioFailure: Error { case missingMoney }

private actor ScenarioTransport: SuggestionTransport {
  private let reply: Data
  private var requests = 0
  init(reply: Data) { self.reply = reply }
  func send(_ request: SuggestionWireRequest) async throws -> Data {
    requests += 1
    return reply
  }
  func count() -> Int { requests }
}
