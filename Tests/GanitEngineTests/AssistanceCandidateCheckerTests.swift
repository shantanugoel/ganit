import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceCandidateCheckerTests {
  private func snapshot(_ text: String, context: EvaluationContext? = nil) throws
    -> AssistanceSnapshot
  {
    let source = SheetSource(text)
    var calculator = SheetCalculator()
    return try calculator.assistanceSnapshot(
      source, context: context ?? sheetContext(), target: source.lines.last!.id)
  }
  private func candidate(
    _ source: String, snapshot: AssistanceSnapshot, names: [String] = [],
    literals: [(String, String)] = [],
    handles: Set<String> = []
  ) throws -> SuggestionCandidate {
    let evidence = snapshot.evidence(including: handles)
    let bindings = try names.map { name in
      SuggestionBinding(
        symbol: name, source: try #require(snapshot.inventory.first { $0.name == name }?.handle))
    }
    let grounded = try literals.map { text, input in
      SuggestionLiteral(
        text: text,
        evidence: try #require(
          evidence.first { $0.kind == "literal" && ($0.text == input || $0.text == input + ".") }?
            .handle))
    }
    return SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: source)],
      bindings: bindings, literals: grounded,
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(
            evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle))
      ],
      assumptions: [], summary: "Review the proposed calculation.")
  }

  private func failureCode(_ operation: () throws -> AssistanceCheckedCandidate)
    -> AssistanceValidationFailure.Code?
  {
    do {
      _ = try operation()
      Issue.record("Expected rejection")
      return nil
    } catch let failure as AssistanceValidationFailure { return failure.code } catch {
      Issue.record("Unexpected validation error: \(error)")
      return nil
    }
  }

  @Test func billUsesGroundedPercentAndLiveReference() throws {
    let snapshot = try snapshot("bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    let proposal = try candidate(
      "share = (bill + 10%) / 4", snapshot: snapshot, names: ["bill"],
      literals: [("10%", "10%"), ("4", "four")])
    let checked = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(
      assistanceValuesEqual(
        checked.result, .money(MoneyValue(amount: .integer(IntegerValue(660)), currency: "INR")),
        context: snapshot.context))
    #expect(checked.isApplicable)
    #expect(checked.referencedLineIDs == [snapshot.source.lines[0].id])
    #expect(snapshot.source.text.contains("Add a 10% tip"))
    #expect(checked.sourceAfter == "bill = 2400 INR\nshare = (bill + 10%) / 4")
  }

  @Test func massRepairRequiresAnExplicitVolumeGoal() throws {
    let withNote = try snapshot(
      "mass = 250 g\ndensity = 0.8 g/ml\n// Find volume from mass and density.\nvolume = mass * density"
    )
    let repaired = try candidate(
      "volume = mass / density", snapshot: withNote, names: ["mass", "density"])
    let checked = try AssistanceCandidateChecker.check(repaired, against: withNote)
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "312.5 ml", context: try sheetContext())
    else {
      Issue.record("Expected volume")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: withNote.context))
    let wrong = try candidate(
      "volume = mass * density", snapshot: withNote, names: ["mass", "density"])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(wrong, against: withNote)
    }
    let withoutNote = try snapshot("mass = 250 g\ndensity = 0.8 g/ml\nvolume = mass * density")
    let inferred = try candidate(
      "volume = mass / density", snapshot: withoutNote, names: ["mass", "density"])
    let review = try AssistanceCandidateChecker.check(inferred, against: withoutNote)
    #expect(!review.isApplicable)
    #expect(review.choices.map(\.id) == ["expected_dimension"])
    #expect(
      try AssistanceCandidateChecker.check(
        inferred, against: withoutNote,
        selectedChoices: ["expected_dimension": "proposed"]
      ).isApplicable)
    #expect(!withoutNote.taskText.contains("volume"))
  }

  @Test func profitNeedsIndependentChoiceEvenWithoutModelAssumptions() throws {
    let snapshot = try snapshot("cost = 1000 INR\nMake 20% profit on cost.")
    let markup = try candidate(
      "price = cost + 20%", snapshot: snapshot, names: ["cost"], literals: [("20%", "20%")])
    let undecided = try AssistanceCandidateChecker.check(markup, against: snapshot)
    #expect(!undecided.isApplicable)
    #expect(undecided.choices.map(\.id) == ["profit_basis"])
    let cost = try AssistanceCandidateChecker.check(
      markup, against: snapshot, selectedChoices: ["profit_basis": "cost"])
    #expect(cost.isApplicable)
    #expect(
      assistanceValuesEqual(
        cost.result, .money(MoneyValue(amount: .integer(IntegerValue(1200)), currency: "INR")),
        context: snapshot.context))
    let margin = try candidate(
      "price = cost / (1 - 20%)", snapshot: snapshot, names: ["cost"], literals: [("20%", "20%")])
    let sale = try AssistanceCandidateChecker.check(
      margin, against: snapshot, selectedChoices: ["profit_basis": "sale"])
    #expect(
      assistanceValuesEqual(
        sale.result, .money(MoneyValue(amount: .integer(IntegerValue(1250)), currency: "INR")),
        context: snapshot.context))
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(
        markup, against: snapshot, selectedChoices: ["profit_basis": "sale"])
    }
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(
        markup, against: snapshot, selectedChoices: ["profit_basis": "unknown"])
    }
  }

  @Test func excludesShippingFromTaxBase() throws {
    let snapshot = try snapshot(
      "items = 100 INR\nshipping = 20 INR\n// Tax applies to items only.\nAdd 10% tax to items and shipping."
    )
    let wrong = try candidate(
      "total cost = (items + shipping) + 10%", snapshot: snapshot, names: ["items", "shipping"],
      literals: [("10%", "10%")])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(wrong, against: snapshot)
    }
    let correct = try candidate(
      "total cost = (items + 10%) + shipping", snapshot: snapshot, names: ["items", "shipping"],
      literals: [("10%", "10%")])
    let checked = try AssistanceCandidateChecker.check(correct, against: snapshot)
    #expect(
      assistanceValuesEqual(
        checked.result, .money(MoneyValue(amount: .integer(IntegerValue(130)), currency: "INR")),
        context: snapshot.context))
  }

  @Test(arguments: [
    "inventedLiteral", "fakeHandle", "unrelatedEdit", "unknownSymbol", "modelValue",
    "functionDefinition", "wrongTip", "wrongSplit",
  ])
  func rejectsUnsafeCandidates(_ attack: String) throws {
    let snapshot = try snapshot("bill = 2400 INR\nAdd a 10% tip to bill, then split it four ways.")
    let base = try candidate(
      "share = (bill + 10%) / 4", snapshot: snapshot, names: ["bill"],
      literals: [("10%", "10%"), ("4", "four")])
    let replacement: String
    switch attack {
    case "inventedLiteral": replacement = "share = (bill + 15%) / 4"
    case "wrongTip": replacement = "share = (bill - 10%) / 4"
    case "wrongSplit": replacement = "share = (bill + 10%) * 4"
    case "unknownSymbol": replacement = "share = (other + 10%) / 4"
    case "modelValue": replacement = "share = ask_assistant(the answer)"
    case "functionDefinition": replacement = "f(x) = x + 10%"
    default: replacement = base.edits[0].replacement
    }
    let candidate = SuggestionCandidate(
      id: base.id,
      edits: [
        SuggestionEdit(target: attack == "unrelatedEdit" ? "T2" : "T1", replacement: replacement)
      ],
      bindings: attack == "fakeHandle"
        ? [SuggestionBinding(symbol: "bill", source: "S99")] : base.bindings,
      literals: base.literals, relations: base.relations, assumptions: [], summary: base.summary)
    let expected: [String: AssistanceValidationFailure.Code] = [
      "inventedLiteral": .missingEvidence, "fakeHandle": .unknownBinding,
      "unrelatedEdit": .unauthorizedEdit,
      "unknownSymbol": .unknownBinding, "modelValue": .unsupportedOperation,
      "functionDefinition": .unsupportedOperation, "wrongTip": .relation, "wrongSplit": .relation,
    ]
    #expect(
      failureCode { try AssistanceCandidateChecker.check(candidate, against: snapshot) }
        == expected[attack])
  }

  @Test func blocksNewDownstreamFailuresAndKeepsExistingOnes() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("// Change this number to 1.\nx = 2\n1 / (x - 1)\n1 / 0")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[1].id)
    let proposal = try candidate("x = 1", snapshot: snapshot, literals: [("1", "1")])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(proposal, against: snapshot)
    }
    let unrelated = try self.snapshot("1 / 0\nAdd 2 and 3.")
    let okay = try candidate("2 + 3", snapshot: unrelated, literals: [("2", "2"), ("3", "3")])
    #expect(try AssistanceCandidateChecker.check(okay, against: unrelated).isApplicable)
  }

  @Test func numberLocaleAndAngleModeAreFrozen() throws {
    let context = try sheetContext(angleMode: .degrees).with(
      localeIdentifier: "de-DE",
      lexingConfiguration: LexingConfiguration(decimalSeparator: ",", groupingSeparator: "."))
    let snapshot = try snapshot("Find sin of 30,0 degrees.", context: context)
    let proposal = try candidate("sin(30,0)", snapshot: snapshot, literals: [("30,0", "30,0")])
    let checked = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(
      assistanceValuesEqual(
        checked.result,
        .number(
          .approximate(
            try ApproximateValue(
              estimate: 0.5, source: .transcendentalFunction, precision: .unspecified))),
        context: context))
  }

  @Test func datesRemainClockExpressionsAndModelFactsAreRejected() throws {
    let snapshot = try snapshot("Find today.")
    let proposal = try candidate("today", snapshot: snapshot)
    let checked = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(checked.result == .date(try DateValue(year: 1970, month: 1, day: 1)))
    let copied = try candidate("1970-01-01", snapshot: snapshot)
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(copied, against: snapshot)
    }
    let missingDensity = try self.snapshot("Convert 250 g into ml.")
    let invented = try candidate(
      "250 g / (1 g/ml)", snapshot: missingDensity, literals: [("250", "250")])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(invented, against: missingDensity)
    }
  }
  @Test func nativeReferencesKeepTheirSourceIdentityAndShowDependentResults() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("// Change the amount to 20.\n10\n@2 + 5")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[1].id)
    let proposal = try candidate("20", snapshot: snapshot, literals: [("20", "20")])
    let checked = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(checked.changedResults == [sheet.lines[2].id])
    #expect(checked.sourceAfter == "// Change the amount to 20.\n20\n@2 + 5")
    #expect(checked.evaluation.lines[2].result == .value(.number(.integer(IntegerValue(25)))))
    let referenceSnapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[2].id)
    let reference = try candidate(
      "@2 + 5", snapshot: referenceSnapshot, names: ["@2"], literals: [("5", "5")])
    let reread = try AssistanceCandidateChecker.check(reference, against: referenceSnapshot)
    #expect(reread.referencedLineIDs == [sheet.lines[1].id])
  }

  @Test func explicitNominalMonthlyRuleRejectsAnnualPaymentRate() throws {
    let snapshot = try snapshot(
      "principal = 1200 INR\nannual rate = 12%\nmonths = 12\n// Use a nominal annual rate with monthly payments.\npayment = pmt(principal, annual rate, months)"
    )
    let wrong = try candidate(
      "payment = pmt(principal, annual rate, months)", snapshot: snapshot,
      names: ["principal", "annual rate", "months"])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(wrong, against: snapshot)
    }
    let correct = try candidate(
      "payment = pmt(principal, annual rate / 12, months)", snapshot: snapshot,
      names: ["principal", "annual rate", "months"])
    let checked = try AssistanceCandidateChecker.check(correct, against: snapshot)
    #expect(checked.isApplicable)
    // Expected payment uses the explicit one-percent monthly rate.
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "pmt(1200 INR, 1%, 12)", context: try sheetContext())
    else {
      Issue.record("Expected a payment")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: snapshot.context))
  }

  @Test func rejectsLegacyModelDependenciesAndRepeatedBindingAliases() throws {
    let snapshot = try snapshot("mass = ask_assistant(a mass)\nConvert mass to ml.")
    let proposal = try candidate("mass in ml", snapshot: snapshot, names: ["mass"])
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(proposal, against: snapshot)
    }
    let bill = try self.snapshot("bill = 2400 INR\nAdd a 10% tip to bill.")
    let valid = try candidate(
      "bill + 10%", snapshot: bill, names: ["bill"], literals: [("10%", "10%")])
    let repeated = SuggestionCandidate(
      id: valid.id, edits: valid.edits, bindings: valid.bindings + valid.bindings,
      literals: valid.literals, relations: valid.relations, assumptions: [], summary: valid.summary)
    #expect(throws: (any Error).self) {
      try AssistanceCandidateChecker.check(repeated, against: bill)
    }
  }

  @Test func volumeCannotSilentlyAssumeWaterDensity() throws {
    let snapshot = try snapshot("Convert 250 g into ml.")
    let wrongButParsable = try candidate("250 ml", snapshot: snapshot, literals: [("250", "250")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(wrongButParsable, against: snapshot) }
        == .missingEvidence)
    let policy = AssistanceSemanticPolicy(snapshot: snapshot, choices: [:])
    #expect(policy.needsDensity(snapshot: snapshot, usedSymbols: [], literalValues: []))
    #expect(policy.requiredChoices(snapshot: snapshot).isEmpty)
  }

  @Test func selectedTaxInclusionCannotAddTaxAgain() throws {
    let snapshot = try snapshot("price = 100 INR\nFind the price with 10% tax.")
    let proposal = try candidate(
      "price + 10%", snapshot: snapshot, names: ["price"], literals: [("10%", "10%")])
    let undecided = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(!undecided.isApplicable)
    #expect(undecided.choices.map(\.id) == ["tax_inclusion"])
    #expect(
      failureCode {
        try AssistanceCandidateChecker.check(
          proposal, against: snapshot, selectedChoices: ["tax_inclusion": "included"])
      } == .relation)
    #expect(
      try AssistanceCandidateChecker.check(
        proposal, against: snapshot, selectedChoices: ["tax_inclusion": "excluded"]
      ).isApplicable)
  }

  @Test func anExplicitReferenceCanReadTheEarlierRedeclarationAcrossADivider() throws {
    let snapshot = try snapshot("amount = 100\namount = 200\n---\n@1 + 1")
    let proposal = try candidate(
      "@1 + 1", snapshot: snapshot, names: ["@1"], literals: [("1", "1")])
    let checked = try AssistanceCandidateChecker.check(proposal, against: snapshot)
    #expect(checked.result == .number(.integer(IntegerValue(101))))
    #expect(checked.referencedLineIDs == [snapshot.source.lines[0].id])
  }

  @Test func importedDefinitionsCannotLaunderLegacyModelValues() throws {
    let prompt = AssistantPrompt([.text("a price")])
    let context = try sheetContext().with(assistantAnswers: [
      prompt: .value(.number(.integer(IntegerValue(1000))))
    ])
    let definitions = try SheetDefinitions(
      source: "cost = ask_assistant(a price)\nprice = cost * 2\nf(x) = price + x", context: context)
    #expect(definitions.unreviewedVariables == ["cost", "price"])
    #expect(definitions.functions["f"]?.hasUnreviewedCapture == true)
    var calculator = SheetCalculator(definitions: definitions)
    let sheet = SheetSource("Make 20% profit on cost.")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[0].id)
    #expect(snapshot.inventory.first { $0.name == "cost" }?.unreviewed == true)
    let proposal = try candidate(
      "cost + 20%", snapshot: snapshot, names: ["cost"], literals: [("20%", "20%")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(proposal, against: snapshot) }
        == .unknownBinding)
    let root = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    let cost = try #require(symbols.first { $0["name"] as? String == "cost" })
    #expect(cost["unreviewed"] as? Bool == true)
    #expect(cost["value"] == nil)
  }

  @Test func modelUnitDefinitionsCannotBecomePreviewFacts() throws {
    let prompt = AssistantPrompt([.text("a weight")])
    guard
      case .value(let amount) = CalculationEngine().evaluate("10 kg", context: try sheetContext())
    else {
      Issue.record("Expected a mass")
      return
    }
    let context = try sheetContext().with(assistantAnswers: [prompt: .value(amount)])
    let definitions = try SheetDefinitions(
      source: "1 bag = ask_assistant(a weight)", context: context)
    #expect(definitions.unreviewedUnits == ["bag"])
    var calculator = SheetCalculator(definitions: definitions)
    let sheet = SheetSource("Convert 2 bags into g.")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[0].id)
    let proposal = try candidate("2 bags in g", snapshot: snapshot, literals: [("2", "2")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(proposal, against: snapshot) }
        == .unsupportedOperation)
  }

  @Test func scaleSuffixesCannotHideInventedNumericFactors() throws {
    let snapshot = try snapshot("bill = 100 INR\nMultiply bill by two.")
    let proposal = try candidate(
      "bill * 2 million", snapshot: snapshot, names: ["bill"], literals: [("2", "two")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(proposal, against: snapshot) }
        == .missingEvidence)
  }

  @Test func errorsCannotBeHiddenByDroppingInputs() throws {
    let zero = try snapshot("1 / 0")
    let removesDivision = try candidate("1", snapshot: zero, literals: [("1", "1")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(removesDivision, against: zero) }
        == .evaluation)
    let missing = try snapshot("x = 1 / 0\nAdd 10% to x.")
    let copiedNumerator = try candidate(
      "1 + 10%", snapshot: missing, literals: [("1", "1"), ("10%", "10%")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(copiedNumerator, against: missing) }
        == .evaluation)
  }

  @Test func quantitiesCannotSupplyPricesOrModelComputedConversions() throws {
    let snapshot = try snapshot("Convert 250 g to INR.")
    let price = try candidate("250 INR", snapshot: snapshot, literals: [("250", "250")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(price, against: snapshot) }
        == .missingEvidence)
    let conversion = try self.snapshot("Convert 250 g to kg.")
    let computed = try candidate("0.25 kg", snapshot: conversion, literals: [("0.25 kg", "250 g")])
    #expect(
      failureCode { try AssistanceCandidateChecker.check(computed, against: conversion) }
        == .missingEvidence)
  }

  @Test func groundedQuantityAndCurrencyLiteralsAreSupported() throws {
    let quantity = try snapshot("Convert 250 g at a density of 0.8 g/ml to ml.")
    let proposal = try candidate(
      "250 g / (0.8 g/ml)", snapshot: quantity,
      literals: [("250 g", "250 g"), ("0.8 g/ml", "0.8 g/ml")])
    let checked = try AssistanceCandidateChecker.check(proposal, against: quantity)
    #expect(checked.isApplicable)
    guard
      case .value(let expected) = CalculationEngine().evaluate(
        "312.5 ml", context: try sheetContext())
    else {
      Issue.record("Expected a volume")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: quantity.context))
    let money = try snapshot("Add 100 INR and 20 INR.")
    let sum = try candidate(
      "100 INR + 20 INR", snapshot: money, literals: [("100 INR", "100 INR"), ("20 INR", "20 INR")])
    #expect(
      try AssistanceCandidateChecker.check(sum, against: money).result
        == .money(MoneyValue(amount: .integer(IntegerValue(120)), currency: "INR")))
  }

  @Test func aUnitSuffixCannotSupplyAScaleFact() throws {
    let context = try sheetContext().with(
      dollarCurrency: "USD", isMarkdownMode: false, ambiguousSuffixes: ["m": .unit])
    let snapshot = try snapshot("Simplify 16m.", context: context)
    #expect(!snapshot.evidence().contains { $0.text == "m" && $0.kind == "literal" })
  }

  @Test func literalBillAndProfitInputsRetainTheKnownRelations() throws {
    let bill = try snapshot("Add a 10% tip to a bill of 2400 INR, then split it four ways.")
    let correct = try candidate(
      "(2400 INR + 10%) / 4", snapshot: bill,
      literals: [("2400 INR", "2400 INR"), ("10%", "10%"), ("4", "four")])
    #expect(try AssistanceCandidateChecker.check(correct, against: bill).isApplicable)
    let wrong = try candidate(
      "2400 INR + 10% / 4", snapshot: bill,
      literals: [("2400 INR", "2400 INR"), ("10%", "10%"), ("4", "four")])
    #expect(failureCode { try AssistanceCandidateChecker.check(wrong, against: bill) } == .relation)
    let profit = try snapshot("Make 20% profit on a cost of 1000 INR.")
    let markup = try candidate(
      "1000 INR + 20%", snapshot: profit, literals: [("1000 INR", "1000 INR"), ("20%", "20%")])
    #expect(try !AssistanceCandidateChecker.check(markup, against: profit).isApplicable)
    #expect(
      try AssistanceCandidateChecker.check(
        markup, against: profit, selectedChoices: ["profit_basis": "cost"]
      ).isApplicable)
  }

  @Test func parameterShadowingDoesNotCaptureAnUnusedModelValue() throws {
    let prompt = AssistantPrompt([.text("a price")])
    let context = try sheetContext().with(assistantAnswers: [
      prompt: .value(.number(.integer(IntegerValue(1000))))
    ])
    let definitions = try SheetDefinitions(
      source: "x = ask_assistant(a price)\nf(x) = x * 2\ny = 10 // x is not an input here",
      context: context)
    #expect(definitions.functions["f"]?.hasUnreviewedCapture == false)
    #expect(!definitions.unreviewedVariables.contains("y"))
  }

}
