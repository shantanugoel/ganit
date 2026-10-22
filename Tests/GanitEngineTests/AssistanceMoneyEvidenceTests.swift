import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceMoneyEvidenceTests {
  @Test(arguments: ["₹25 lakh", "25 lakh INR", "₹2.5 million"])
  func nativeScaledMoneyProducesExactSourceEvidence(_ phrase: String) throws {
    var calculator = SheetCalculator()
    let source = SheetSource("Borrow \(phrase) and calculate the principal.")
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[0].id)
    let evidence = try #require(
      snapshot.evidence().first { $0.kind == "literal" && $0.text == phrase })
    let expected = EngineValue.money(
      MoneyValue(amount: .integer(IntegerValue(2_500_000)), currency: "INR"))
    #expect(
      assistanceValuesEqual(try #require(evidence.value), expected, context: snapshot.context))
    let relation = try #require(snapshot.evidence().first { $0.kind == "relation" })
    let candidate = SuggestionCandidate(
      id: "scaled-money", edits: [SuggestionEdit(target: "T1", replacement: "2500000 INR")],
      bindings: [], literals: [SuggestionLiteral(text: "2500000 INR", evidence: evidence.handle)],
      relations: [SuggestionRelation(rule: "interpretation", evidence: relation.handle)],
      assumptions: [], summary: "Use the supplied principal.")
    let checked = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    #expect(checked.isApplicable)
    #expect(assistanceValuesEqual(checked.result, expected, context: snapshot.context))
  }

  @Test(arguments: ["₹(25 * 100000)", "₹(25 + 100000)", "₹(25 * lakh)"])
  func arithmeticDoesNotBecomeALiteralMoneyEvidence(_ phrase: String) throws {
    var calculator = SheetCalculator()
    let source = SheetSource("Borrow \(phrase) and calculate the principal.")
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[0].id)
    #expect(!snapshot.evidence().contains { $0.kind == "literal" && $0.text == phrase })
  }

  @Test func aDeclaredScaleNameDoesNotBecomeMoneyEvidence() throws {
    var calculator = SheetCalculator()
    let source = SheetSource("lakh = 7\nBorrow ₹25 lakh and calculate the principal.")
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[1].id)
    #expect(!snapshot.evidence().contains { $0.kind == "literal" && $0.text == "₹25 lakh" })
  }
}
