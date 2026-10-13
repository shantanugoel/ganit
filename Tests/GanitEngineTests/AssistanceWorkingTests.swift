import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceWorkingTests {
  private let request = ["Add a 10% tip to bill.", "Then split it four equal ways."]

  private func snapshot(_ text: String, target: Range<Int>) throws -> AssistanceSnapshot {
    let source = SheetSource(text)
    var calculator = SheetCalculator()
    return try calculator.assistanceSnapshot(
      source, context: sheetContext(), targets: Array(source.lines[target].map(\.id)))
  }

  private func proposal(
    _ source: String, snapshot: AssistanceSnapshot, locals: [(String, String)] = [],
    inputName: String = "bill"
  ) throws -> SuggestionCandidate {
    let evidence = snapshot.evidence()
    let bill = try #require(snapshot.inventory.first { $0.name == inputName }?.handle)
    let bindings =
      [SuggestionBinding(symbol: inputName, source: bill)]
      + locals.map { SuggestionBinding(symbol: $0.0, source: $0.1) }
    return SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: source)], bindings: bindings,
      literals: [
        SuggestionLiteral(
          text: "10%", evidence: try #require(evidence.first { $0.text == "10%" }?.handle)),
        SuggestionLiteral(
          text: "4", evidence: try #require(evidence.first { $0.text == "four" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Add the stated tip, then split equally.")
  }

  private func expectShare(_ checked: AssistanceCheckedCandidate) throws {
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "660 INR", context: try sheetContext())
    else {
      Issue.record("Expected the fixture result")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: try sheetContext()))
  }

  @Test(arguments: ["\n", "\r\n", "\r"])
  func aParagraphIsOneBoundedTargetWithExactSource(_ separator: String) throws {
    let source = ["bill = 2400 INR"] + request + ["other = 7", "@4"]
    let snapshot = try snapshot(source.joined(separator: separator), target: 1..<3)
    #expect(snapshot.targetText == request.joined(separator: separator))
    let encoded = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    #expect((encoded["target"] as? [String: String])?["source"] == snapshot.targetText)
    let candidate = try proposal("share = (bill + 10%) / 4", snapshot: snapshot)
    let checked = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    try expectShare(checked)
    #expect(checked.sourceAfter.hasSuffix("other = 7" + separator + "@3"))
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(candidate, against: snapshot)
    #expect(
      edit.sourceAfter
        == (["bill = 2400 INR", "share = (bill + 10%) / 4"]
        + request.map { "// Request record: " + $0 } + ["other = 7", "@5"]).joined(
          separator: separator))
  }

  @Test func completeWorkingUsesNativeDerivedBindingsAndTheLastResult() throws {
    let snapshot = try snapshot(
      (["bill = 2400 INR"] + request + ["other = 7", "@4"]).joined(separator: "\n"), target: 1..<3)
    let source = "tip = bill * 10%\nwithtip = bill + tip\nshare = withtip / 4"
    let candidate = try proposal(
      source, snapshot: snapshot, locals: [("tip", "L1"), ("withtip", "L2")])
    let checked = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    try expectShare(checked)
    #expect(
      checked.evaluation.lines.first { $0.id == checked.resultLineID }?.result
        == .value(checked.result))
    #expect(checked.sourceAfter.hasSuffix("other = 7\n@5"))
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(candidate, against: snapshot)
    #expect(edit.sourceAfter.hasSuffix("other = 7\n@7"))
    #expect(edit.sourceAfter.contains("// Request record: " + request[0]))
    #expect(edit.sourceAfter.contains("// Request record: " + request[1]))
  }

  @Test func derivedAmountsCannotDisableTheIndependentTipConstraint() throws {
    let snapshot = try snapshot(
      "amount = 2400 INR\nAdd a 10% tip to amount, then split it four equal ways.", target: 1..<2)
    let locals = [("tip", "L1"), ("withtip", "L2")]
    let correct = try proposal(
      "tip = amount * 10%\nwithtip = amount + tip\nshare = withtip / 4",
      snapshot: snapshot, locals: locals, inputName: "amount")
    try expectShare(AssistanceCandidateChecker.check(correct, against: snapshot))
    let incorrect = try proposal(
      "tip = amount * 10%\nwithtip = amount - tip\nshare = withtip / 4",
      snapshot: snapshot, locals: locals, inputName: "amount")
    do {
      _ = try AssistanceCandidateChecker.check(incorrect, against: snapshot)
      Issue.record("Expected the independent tip constraint")
    } catch let failure as AssistanceValidationFailure {
      #expect(failure.code == .relation)
    }
  }

  @Test func anIntermediateCalculationCannotSupplyNewLiteralEvidence() throws {
    let snapshot = try snapshot(
      (["bill = 2400 INR"] + request).joined(separator: "\n"), target: 1..<3)
    for source in [
      "unused = 123456\nshare = (bill + 10%) / 4", "withtip = bill + 10%\nshare = 2640 / 4",
    ] {
      let candidate = try proposal(source, snapshot: snapshot)
      #expect(throws: AssistanceValidationFailure.self) {
        try AssistanceCandidateChecker.check(candidate, against: snapshot)
      }
    }
  }

  @Test func aDerivedBindingCannotPretendToReadAnOriginalDeclaration() throws {
    let snapshot = try snapshot(
      (["bill = 2400 INR"] + request).joined(separator: "\n"), target: 1..<3)
    let candidate = try proposal(
      "tip = bill * 10%\nshare = (bill + tip) / 4", snapshot: snapshot, locals: [("tip", "S99")])
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
  }

  @Test func multipleExistingNamesAndCommentsMustRemainExactlyOnce() throws {
    let snapshot = try snapshot(
      "leftval = 2 // keep\nrightval = 3 // also\nleftval + rightval", target: 0..<3)
    let evidence = snapshot.evidence()
    func candidate(_ source: String) throws -> SuggestionCandidate {
      SuggestionCandidate(
        id: "C1", edits: [SuggestionEdit(target: "T1", replacement: source)],
        bindings: [
          SuggestionBinding(symbol: "leftval", source: "L1"),
          SuggestionBinding(symbol: "rightval", source: "L2"),
        ],
        literals: [
          SuggestionLiteral(
            text: "2", evidence: try #require(evidence.first { $0.text == "2" }?.handle)),
          SuggestionLiteral(
            text: "3", evidence: try #require(evidence.first { $0.text == "3" }?.handle)),
        ],
        relations: [
          SuggestionRelation(
            rule: "interpretation",
            evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
        ], assumptions: [], summary: "Keep the inputs and add them.")
    }
    let valid = try candidate(
      "leftval = 2 // keep\nrightval = 3 // also\nanswer = leftval + rightval")
    #expect(
      try AssistanceCandidateChecker.check(valid, against: snapshot).result
        == .number(.integer(IntegerValue(5))))
    let renamed = try candidate(
      "renamed = 2 // keep\nrightval = 3 // also\nanswer = renamed + rightval")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(renamed, against: snapshot)
    }
  }

  @Test func aDomainErrorOnAnySelectedLineStillRequiresAnInputRevision() throws {
    let snapshot = try snapshot("Use two as a denominator.\n4 / 0", target: 0..<2)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "4 / 2")], bindings: [],
      literals: [
        SuggestionLiteral(
          text: "4", evidence: try #require(evidence.first { $0.text == "4" }?.handle)),
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ], assumptions: [], summary: "Use the revised denominator.")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
    #expect(
      try AssistanceCandidateChecker.check(candidate, against: snapshot, userRevisedInputs: true)
        .result == .number(.integer(IntegerValue(2))))
  }

  @Test func anOversizedSelectionIsNotTruncatedOrEvaluated() throws {
    let source = SheetSource(
      Array(repeating: "Add two and three.", count: 13).joined(separator: "\n"))
    var calculator = SheetCalculator()
    #expect(throws: AssistanceSnapshotError.targetTooLarge) {
      try calculator.assistanceSnapshot(
        source, context: sheetContext(), targets: source.lines.map(\.id))
    }
    #expect(calculator.generation == 0)
  }
  @Test func anAmbiguousExistingReferenceRequiresAnExplicitResultChoice() throws {
    let text = "bill = 2400 INR\nAdd a 10% tip to bill, then split it four equal ways.\n@2"
    let snapshot = try snapshot(text, target: 1..<2)
    let candidate = try proposal(
      "tip = bill * 10%\nwithtip = bill + tip\nshare = withtip / 4", snapshot: snapshot,
      locals: [("tip", "L1"), ("withtip", "L2")])
    let unresolved = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    try expectShare(unresolved)
    #expect(!unresolved.isApplicable)
    let choice = try #require(unresolved.choices.first { $0.id.hasPrefix("reference_") })
    #expect(choice.options.count == 3)
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.prepareSourceEdit(candidate, against: snapshot)
    }
    let selected = [choice.id: "line_3"]
    let checked = try AssistanceCandidateChecker.check(
      candidate, against: snapshot, selectedChoices: selected)
    #expect(checked.isApplicable)
    #expect(checked.sourceAfter.hasSuffix("@4"))
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(
      candidate, against: snapshot, selectedChoices: selected)
    #expect(edit.sourceAfter.hasSuffix("@4"))
    #expect(edit.evaluation.lines.last?.result == .value(checked.result))
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(
        candidate, against: snapshot, selectedChoices: [choice.id: "line_99"])
    }
  }

  @Test func aTableFormulaReferenceUsesTheReviewedResultAndKeepsItsLedger() throws {
    let (text, tableID) = try TableLineReferenceTests.sheet(
      head: "Add two and three.\n", amounts: ["=@1 * [@Qty]", "=line 1 + [@Qty]"], tail: "")
    let snapshot = try snapshot(text, target: 0..<1)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1",
      edits: [SuggestionEdit(target: "T1", replacement: "part = 2 + 3\nresult = part * 1")],
      bindings: [SuggestionBinding(symbol: "part", source: "L1")],
      literals: [
        SuggestionLiteral(
          text: "2",
          evidence: try #require(
            evidence.first { $0.text == "two" }?.handle)),
        SuggestionLiteral(
          text: "3",
          evidence: try #require(
            evidence.first { $0.text == "three" }?.handle)),
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: [], summary: "Add the supplied numbers.")
    let unresolved = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    let choice = try #require(unresolved.choices.first { $0.id.hasPrefix("reference_") })
    #expect(!unresolved.isApplicable)
    let edit = try AssistanceCandidateChecker.prepareSourceEdit(
      candidate, against: snapshot, selectedChoices: [choice.id: "line_2"])
    let model = try TableLineReferenceTests.model(edit.sourceAfter, tableID)
    #expect(TableLineReferenceTests.formula(model, row: 0, column: 1) == "=@2 * [@Qty]")
    #expect(TableLineReferenceTests.formula(model, row: 1, column: 1) == "=line 2 + [@Qty]")
    #expect(model.ledger.count == 2)
    #expect(
      model.ledger.contains {
        $0.fingerprint == "=line 2 + [@Qty]"
          && $0.bindings.map(\.operand) == [10..<16]
      })
    #expect(TableSheetFoldTests.cell(edit.evaluation, tableID, row: 0, column: 1) == "10")
    #expect(TableSheetFoldTests.cell(edit.evaluation, tableID, row: 1, column: 1) == "9")
  }

  @Test func aNominalMonthlyRateCanBeAnEarlierDerivedDeclaration() throws {
    let snapshot = try snapshot(
      "balance = 600000 INR\nterm = 120\nFind monthly payments with a nominal annual rate of 6% for balance and term.",
      target: 2..<3)
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1",
      edits: [
        SuggestionEdit(
          target: "T1",
          replacement: "monthlyrate = 6% / 12\npayment = pmt(balance, monthlyrate, term)")
      ],
      bindings: [
        SuggestionBinding(
          symbol: "balance",
          source: try #require(snapshot.inventory.first { $0.name == "balance" }?.handle)),
        SuggestionBinding(
          symbol: "term",
          source: try #require(snapshot.inventory.first { $0.name == "term" }?.handle)),
        SuggestionBinding(symbol: "monthlyrate", source: "L1"),
      ],
      literals: [
        SuggestionLiteral(
          text: "6%", evidence: try #require(evidence.first { $0.text == "6%" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ], assumptions: [], summary: "Use twelve nominal monthly periods.")
    let checked = try AssistanceCandidateChecker.check(candidate, against: snapshot)
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "pmt(600000 INR, 0.5%, 120)", context: try sheetContext())
    else {
      Issue.record("Expected a payment")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: try sheetContext()))
  }

  @Test func derivedExpansionCannotExceedTheNativeOperationLimit() throws {
    let snapshot = try snapshot("Use two in the repeated calculation.", target: 0..<1)
    let names = ["startval", "nextval", "thirdval", "fourthval", "fifthval", "sixthval", "lastval"]
    var working = [names[0] + " = 2"]
    for index in 1..<names.count {
      working.append(
        names[index] + " = "
          + Array(repeating: names[index - 1], count: 8).joined(separator: " + "))
    }
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: working.joined(separator: "\n"))],
      bindings: names.dropLast().enumerated().map {
        SuggestionBinding(symbol: $0.element, source: "L\($0.offset + 1)")
      },
      literals: [
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ], assumptions: [], summary: "Use bounded repeated working.")
    do {
      _ = try AssistanceCandidateChecker.check(candidate, against: snapshot)
      Issue.record("Expected the native operation limit")
    } catch let failure as AssistanceValidationFailure {
      #expect(failure.code == .evaluation)
      if case .evaluationFailure(let error) = failure.engineResult {
        #expect(error.code == .resourceLimitExceeded)
      } else {
        Issue.record("Expected a native resource diagnostic")
      }
    }
  }

  @Test func derivedExpansionCannotExceedTheNativeDepthLimit() throws {
    let snapshot = try snapshot("Use two in the grouped calculation.", target: 0..<1)
    func grouped(_ text: String) -> String {
      String(repeating: "(", count: 12) + text + String(repeating: ")", count: 12)
    }
    let names = [
      "firstval", "nextval", "thirdval", "fourthval", "fifthval", "sixthval",
      "seventhval", "eighthval", "ninthval", "tenthval", "eleventhval", "lastval",
    ]
    let working = names.enumerated().map { index, name in
      name + " = " + grouped(index == 0 ? "2" : names[index - 1])
    }.joined(separator: "\n")
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: working)],
      bindings: names.dropLast().enumerated().map {
        SuggestionBinding(symbol: $0.element, source: "L\($0.offset + 1)")
      },
      literals: [
        SuggestionLiteral(
          text: "2",
          evidence: try #require(
            evidence.first { $0.text == "two" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: [], summary: "Use bounded grouped working.")
    do {
      _ = try AssistanceCandidateChecker.check(candidate, against: snapshot)
      Issue.record("Expected the native depth limit")
    } catch let failure as AssistanceValidationFailure {
      #expect(failure.code == .evaluation)
      if case .evaluationFailure(let error) = failure.engineResult {
        #expect(error.code == .resourceLimitExceeded)
      } else {
        Issue.record("Expected a native resource diagnostic")
      }
    }
  }

  @Test func allSelectedDiagnosticsHaveRangesInTheParagraphTarget() throws {
    let snapshot = try snapshot("1 + 2\n4 / 0", target: 0..<2)
    let root = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    let diagnostics = try #require(root["diagnostics"] as? [[String: Any]])
    let failure = try #require(
      diagnostics.first { $0["code"] as? String == "evaluation.divisionByZero" })
    let spans = try #require(failure["spans"] as? [[String: Int]])
    #expect(spans.allSatisfy { ($0["utf8Start"] ?? 0) >= 6 })
  }

}
