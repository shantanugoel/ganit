import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceSourceEditTests {
  private func proposal(_ snapshot: AssistanceSnapshot, assumptions: [SuggestionAssumption] = [])
    throws -> SuggestionCandidate
  {
    let evidence = snapshot.evidence()
    func handle(_ text: String) throws -> String {
      try #require(evidence.first { $0.text == text && $0.kind == "literal" }?.handle)
    }
    return SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "2 + 3")],
      bindings: [],
      literals: [
        SuggestionLiteral(text: "2", evidence: try handle("two")),
        SuggestionLiteral(text: "3", evidence: try handle("three")),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: assumptions, summary: "Add the two supplied numbers.")
  }

  @Test(arguments: ["\n", "\r\n", "\r"])
  func recordPreservesTheResultIdentityAndRenumbersOtherReferences(_ separator: String) throws {
    let source = SheetSource(
      ["// café 👩🏽‍💻", "Add two and three.", "x = 8", "@3 + @2"].joined(separator: separator))
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[1].id)
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(
      proposal(snapshot), against: snapshot)
    #expect(edit.sourceBefore == source.text)
    #expect(
      edit.sourceAfter
        == ["// café 👩🏽‍💻", "2 + 3", "// Request record: Add two and three.", "x = 8", "@4 + @2"]
        .joined(separator: separator))
    #expect(edit.evaluation.lines[1].id == source.lines[1].id)
    #expect(edit.evaluation.lines.last?.result == .value(.number(.integer(IntegerValue(13)))))
  }

  @Test func finalLineKeepsARecordAndApprovedTaskNotes() throws {
    let source = SheetSource("Add two and three.")
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[0].id
    )
    .addingTaskNote("Use an equal addition.")
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(
      proposal(snapshot), against: snapshot)
    #expect(
      edit.sourceAfter
        == "2 + 3\n// Request record: Add two and three.\n// Task record: Use an equal addition.")
    #expect(edit.evaluation.lines[0].id == source.lines[0].id)
    var next = SheetSource(edit.sourceAfter + "\nReview x")
    let follow = try calculator.assistanceSnapshot(
      next, context: sheetContext(), target: next.lines.last!.id)
    #expect(follow.notes.allSatisfy { $0.historical })
    next.replace(utf8Range: 0..<5, with: "20 + 3")
    #expect(
      try calculator.evaluate(next, context: sheetContext()).lines[0].result
        == .value(.number(.integer(IntegerValue(23)))))
  }

  @Test func anUnapprovedAssumptionCannotEnterSource() throws {
    let source = SheetSource("Add two and three.")
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[0].id)
    let relation = try #require(snapshot.evidence().first { $0.kind == "relation" }?.handle)
    let candidate = try proposal(
      snapshot,
      assumptions: [SuggestionAssumption(id: "A1", text: "Use equal weights.", evidence: relation)])
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.prepareSourceEdit(candidate, against: snapshot)
    }
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.prepareSourceEdit(
        candidate, against: snapshot, approvedAssumptions: ["A1"])
    }
  }
}
