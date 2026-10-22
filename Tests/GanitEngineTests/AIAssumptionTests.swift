import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

/// M3's checked world-fact declaration: the model may name one fact, Ganit
/// checks it, and it lands as a declared value with an origin comment.
@Suite
struct AIAssumptionTests {
  /// The reader's mass is an ordinary source record that sits outside the
  /// target line, so it reaches a proposal the same way it does in the app: as
  /// a record the reader included in the disclosed context.
  private struct Case {
    let snapshot: AssistanceSnapshot
    let candidate: SuggestionCandidate
    let included: Set<String>
  }

  private func fixture(
    replacement: String = "density = 1 g/ml\nvolume = mass / density in ml",
    basis: String = "Density of water at 4 °C", name: String = "density"
  ) throws -> Case {
    let source = SheetSource("mass = 10 kg\nFind the volume of this water in ml.")
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines.last!.id)
    let relation = try #require(
      snapshot.evidence().first { $0.kind == "relation" && $0.source == "T1" }?.handle)
    let mass = try #require(snapshot.inventory.first { $0.name == "mass" }?.handle)
    return Case(
      snapshot: snapshot,
      candidate: SuggestionCandidate(
        id: "water", edits: [.init(target: "T1", replacement: replacement)],
        bindings: [.init(symbol: "mass", source: mass), .init(symbol: name, source: "L1")],
        literals: [.init(text: "1 g/ml", evidence: "A1")],
        relations: [.init(rule: "interpretation", evidence: relation)],
        assumptions: [.init(id: "A1", text: basis, evidence: relation)],
        summary: "Divide mass by water density."),
      included: [mass])
  }

  @Test func waterUsesOneDeclaredFactAndTheEngineCalculatesTenThousandMillilitres() throws {
    let fixture = try fixture()
    let preview = try AssistanceCandidateChecker.check(
      fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included)
    #expect(!preview.isApplicable)
    #expect(preview.requiresAssumptionApproval)
    #expect(preview.choices.isEmpty)
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "10000 ml", context: try sheetContext())
    else {
      Issue.record("Expected a native volume.")
      return
    }
    #expect(
      assistanceValuesEqual(preview.result, expected, context: try sheetContext()))
    let approved = try AssistanceCandidateChecker.check(
      fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
      approvedAssumptions: ["A1"])
    #expect(approved.isApplicable)
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(
      fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
      approvedAssumptions: ["A1"],
      assumptionModel: "fixture-model", assumptionDate: "2026-10-22")
    #expect(
      edit.sourceAfter.contains(
        "density = 1 g/ml // AI: Density of water at 4 °C · fixture-model · 2026-10-22"))
    #expect(!edit.sourceAfter.contains("// Approved assumption:"))
    let line = try #require(
      edit.sourceAfter.components(separatedBy: "\n").first { $0.hasPrefix("density =") })
    let marker = try #require(AIAssumption.parse(line))
    #expect(marker.basis == "Density of water at 4 °C")
    #expect(marker.model == "fixture-model")
    #expect(marker.date == "2026-10-22")
  }

  @Test func aFactWithoutItsRecordIsNotChecked() throws {
    // Without the included record the mass is not in the permitted context, so
    // the proposal cannot be checked at all rather than checked loosely.
    let fixture = try fixture()
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(
        fixture.candidate, against: fixture.snapshot, approvedAssumptions: ["A1"])
    }
  }

  @Test func aFactCannotBeEmbeddedInArithmeticOrUsedAsAnUnmarkedAnswer() throws {
    for source in [
      "volume = mass / (1 g/ml) in ml", "1 g/ml",
      "density = (1 g/ml) * 2\nvolume = mass / density in ml",
    ] {
      let fixture = try fixture(replacement: source)
      #expect(throws: AssistanceValidationFailure.self) {
        try AssistanceCandidateChecker.check(
          fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
          approvedAssumptions: ["A1"])
      }
    }
  }

  @Test func anAssumptionCannotGroundAnotherOccurrenceOfTheSameLiteral() throws {
    let fixture = try fixture(
      replacement: "density = 1 g/ml\nvolume = mass / (1 g/ml) in ml")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(
        fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
        approvedAssumptions: ["A1"])
    }
  }

  @Test func personalInputsAndUncertainPropertiesCannotBeAssumed() throws {
    for basis in [
      "Tax rate for water", "Salary currency", "Budget density", "A useful estimate",
      "Density for a loan",
    ] {
      let fixture = try fixture(basis: basis)
      #expect(throws: AssistanceValidationFailure.self) {
        try AssistanceCandidateChecker.check(
          fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
          approvedAssumptions: ["A1"])
      }
    }
  }

  @Test func onlyOneWorldFactCanBeDeclaredPerProposal() throws {
    let fixture = try fixture()
    let original = fixture.candidate
    let candidate = SuggestionCandidate(
      id: original.id, edits: original.edits, bindings: original.bindings,
      literals: original.literals, relations: original.relations,
      assumptions: original.assumptions + [
        .init(id: "A2", text: "Density of steel", evidence: original.assumptions[0].evidence)
      ],
      summary: original.summary)
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(
        candidate, against: fixture.snapshot, permittedHandles: fixture.included,
        approvedAssumptions: ["A1", "A2"])
    }
  }

  @Test func theModelCannotWriteTheOriginMarker() throws {
    let fixture = try fixture(
      replacement:
        "density = 1 g/ml // AI: Density of water · fake · 2026-10-22\nvolume = mass / density in ml"
    )
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(
        fixture.candidate, against: fixture.snapshot, permittedHandles: fixture.included,
        approvedAssumptions: ["A1"])
    }
    #expect(
      AIAssumption.parse("volume = mass / density // AI: Density of water · fake · 2026-10-22")
        == nil)
    #expect(AIAssumption.parse("1 g/ml // AI: Density of water · fake · 2026-10-22") == nil)
  }
}
