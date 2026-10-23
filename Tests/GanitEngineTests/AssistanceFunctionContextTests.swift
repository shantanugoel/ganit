import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceFunctionContextTests {
  private func snapshot(_ text: String, definitions: SheetDefinitions = .none) throws
    -> AssistanceSnapshot
  {
    let source = SheetSource(text)
    var calculator = SheetCalculator(definitions: definitions)
    return try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines.last!.id)
  }

  private func root(_ snapshot: AssistanceSnapshot, handles: Set<String> = []) throws -> [String:
    Any]
  {
    try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext(including: handles))
        as? [String: Any])
  }

  private func function(_ snapshot: AssistanceSnapshot, name: String) throws -> [[String: Any]] {
    let symbols = try #require(root(snapshot)["symbols"] as? [[String: Any]])
    let symbol = try #require(symbols.first { $0["name"] as? String == name })
    #expect(symbol["unavailable"] as? Bool == false)
    let context = try #require(symbol["function"] as? [String: Any])
    return try #require(context["definitions"] as? [[String: Any]])
  }

  private func candidate(
    _ source: String, snapshot: AssistanceSnapshot, name: String = "f", handles: Set<String> = []
  ) throws -> SuggestionCandidate {
    let evidence = snapshot.evidence(including: handles)
    let two = try #require(evidence.first { $0.kind == "literal" && $0.text == "two" }?.handle)
    let relation = try #require(
      evidence.first { $0.kind == "relation" && $0.source == "T1" }?.handle)
    let handle = try #require(
      snapshot.inventory.first { $0.kind == "function" && $0.name == name }?.handle)
    return SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: source)],
      bindings: [SuggestionBinding(symbol: name, source: handle)],
      literals: [SuggestionLiteral(text: "2", evidence: two)],
      relations: [SuggestionRelation(rule: "interpretation", evidence: relation)],
      assumptions: [], summary: "Use the selected function with the supplied argument.")
  }

  @Test func capturesRetainTheOriginalDeclarationAcrossRedeclaration() throws {
    let snapshot = try snapshot(
      "factor = 10\nf(x) = x * factor\nfactor = 20\nsecret = 987654\nUse f with two.")
    let definitions = try function(snapshot, name: "f")
    #expect(definitions.count == 1)
    let captures = try #require(definitions[0]["captures"] as? [[String: Any]])
    #expect(captures.count == 1)
    #expect(captures[0]["source"] as? String == "factor = 10")
    #expect((captures[0]["origin"] as? String)?.hasPrefix("source:") == true)
    let value = try #require(captures[0]["value"] as? [String: Any])
    let amount = try #require(value["amount"] as? [String: Any])
    #expect(amount["kind"] as? String == "integer")
    #expect(amount["digits"] as? String == "10")
    let json = String(decoding: try snapshot.permittedContext(), as: UTF8.self)
    #expect(!json.contains("factor = 20"))
    #expect(!json.contains("secret"))
    #expect(!json.contains("987654"))
    let checked = try AssistanceCandidateChecker.check(
      candidate("f(2)", snapshot: snapshot), against: snapshot)
    #expect(checked.result == .number(.integer(IntegerValue(20))))
    #expect(
      Set(checked.referencedLineIDs)
        == Set([snapshot.source.lines[0].id, snapshot.source.lines[1].id]))
  }

  @Test func nestedCallsRetainTheirCapturedFunctionVersions() throws {
    let snapshot = try snapshot(
      "factor = 3\ndouble(x) = x * factor\nf(x) = double(x)\ndouble(x) = x * 9\nUse f with two.")
    let definitions = try function(snapshot, name: "f")
    #expect(definitions.count == 2)
    let g = try #require(definitions.first { $0["name"] as? String == "double" })
    #expect(g["source"] as? String == "double(x) = x * factor")
    #expect(!String(decoding: try snapshot.permittedContext(), as: UTF8.self).contains("x * 9"))
    let checked = try AssistanceCandidateChecker.check(
      candidate("f(2)", snapshot: snapshot), against: snapshot)
    #expect(checked.result == .number(.integer(IntegerValue(6))))
  }

  @Test func importedCapturesDoNotRequireReadingTheDefinitionsSheet() throws {
    let definitions = try SheetDefinitions(
      source: "factor = 7\nf(x) = x * factor\nprivate = 555555", context: sheetContext())
    let snapshot = try snapshot("factor = 11\nUse f with two.", definitions: definitions)
    let records = try function(snapshot, name: "f")
    #expect((records[0]["origin"] as? String)?.hasPrefix("source:") == true)
    let captures = try #require(records[0]["captures"] as? [[String: Any]])
    #expect((captures[0]["origin"] as? String)?.hasPrefix("source:") == true)
    #expect(captures[0]["source"] as? String == "factor = 7")
    let json = String(decoding: try snapshot.permittedContext(), as: UTF8.self)
    #expect(!json.contains("555555"))
    #expect(!json.contains("factor = 11"))
    let checked = try AssistanceCandidateChecker.check(
      candidate("f(2)", snapshot: snapshot), against: snapshot)
    #expect(checked.result == .number(.integer(IntegerValue(14))))
  }

  @Test func parametersShadowVariablesAndCommentNamesAreNotCaptures() throws {
    let snapshot = try snapshot(
      "x = 888888\nprivate = 777777\nf(x) = x // private\nUse f with two.")
    let definitions = try function(snapshot, name: "f")
    #expect((definitions[0]["captures"] as? [[String: Any]])?.isEmpty == true)
    let json = String(decoding: try snapshot.permittedContext(), as: UTF8.self)
    #expect(!json.contains("888888"))
    #expect(!json.contains("777777"))
    #expect(
      try AssistanceCandidateChecker.check(candidate("f(2)", snapshot: snapshot), against: snapshot)
        .result == .number(.integer(IntegerValue(2))))
  }

  @Test func anUnselectedFunctionRequiresExplicitContextAndBinding() throws {
    let snapshot = try snapshot("f(x) = x * 3\nUse the previous function with two.")
    let handle = try #require(snapshot.inventory.first { $0.kind == "function" }?.handle)
    #expect(!String(decoding: try snapshot.permittedContext(), as: UTF8.self).contains("x * 3"))
    let candidate = try candidate("f(2)", snapshot: snapshot, handles: [handle])
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
    #expect(
      try AssistanceCandidateChecker.check(candidate, against: snapshot, permittedHandles: [handle])
        .result == .number(.integer(IntegerValue(6))))
    let unbound = SuggestionCandidate(
      id: candidate.id, edits: candidate.edits, bindings: [], literals: candidate.literals,
      relations: candidate.relations, assumptions: [], summary: candidate.summary)
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(unbound, against: snapshot, permittedHandles: [handle])
    }
  }

  @Test func compiledCustomUnitsStayInTheFunctionRecord() throws {
    let snapshot = try snapshot("1 bag = 25 kg\nf(x) = x * 1 bag\nUse f with two.")
    let definitions = try function(snapshot, name: "f")
    let units = try #require(definitions[0]["units"] as? [[String: Any]])
    #expect(units.count == 1)
    #expect(String(describing: units[0]).contains("bag"))
    let checked = try AssistanceCandidateChecker.check(
      candidate("f(2)", snapshot: snapshot), against: snapshot)
    let engine = CalculationEngine()
    guard case .value(let expected) = engine.evaluate("50 kg", context: try sheetContext()) else {
      Issue.record("Expected a quantity")
      return
    }
    #expect(assistanceValuesEqual(checked.result, expected, context: try sheetContext()))
  }
  @Test func equalPhysicalLineIDsFromDifferentSourcesCannotMergeClosures() throws {
    var calculator = SheetCalculator()
    let exported = try calculator.evaluate(
      SheetSource("base = 7\ndouble(x) = x * base"), context: sheetContext()
    ).definitions
    let snapshot = try snapshot(
      "spare = 0\nf(x) = double(x)\nUse f with two.", definitions: exported)
    let records = try function(snapshot, name: "f")
    try #require(records.count == 2)
    #expect(records[0]["origin"] as? String != records[1]["origin"] as? String)
    #expect((records[0]["origin"] as? String)?.hasPrefix("source:") == true)
    #expect((records[1]["origin"] as? String)?.hasPrefix("source:") == true)
    #expect(
      try AssistanceCandidateChecker.check(candidate("f(2)", snapshot: snapshot), against: snapshot)
        .result == .number(.integer(IntegerValue(14))))
  }

  @Test func largeClosureContextIsRejectedWithoutTruncation() throws {
    let source =
      (["f(x) = x"] + Array(repeating: "f(x) = f(x) + 1", count: 70) + ["Use f with two."]).joined(
        separator: "\n")
    let snapshot = try snapshot(source)
    #expect(throws: AssistanceSnapshotError.contextTooLarge) { try snapshot.permittedContext() }
  }

  @Test func rationalCapturesKeepTheirExactTerms() throws {
    let snapshot = try snapshot("factor = 1 / 3\nf(x) = x * factor\nUse f with two.")
    let records = try function(snapshot, name: "f")
    let captures = try #require(records[0]["captures"] as? [[String: Any]])
    let value = try #require(captures[0]["value"] as? [String: Any])
    let amount = try #require(value["amount"] as? [String: Any])
    #expect(amount["kind"] as? String == "rational")
    #expect(amount["numerator"] as? String == "1")
    #expect(amount["denominator"] as? String == "3")
  }

  @Test func failedCaptureCannotBeHiddenByDroppingTheFunction() throws {
    let snapshot = try snapshot("factor = 1 / 0\nf(x) = x * factor\nUse f with two.")
    let using = try candidate("f(2)", snapshot: snapshot)
    let dropping = SuggestionCandidate(
      id: using.id, edits: [SuggestionEdit(target: "T1", replacement: "2")],
      bindings: [], literals: using.literals, relations: using.relations, assumptions: [],
      summary: "Use the supplied argument.")
    for candidate in [using, dropping] {
      #expect(throws: AssistanceValidationFailure.self) {
        try AssistanceCandidateChecker.check(candidate, against: snapshot)
      }
    }
    let records = try function(snapshot, name: "f")
    let captures = try #require(records[0]["captures"] as? [[String: Any]])
    #expect(captures[0]["unavailable"] as? Bool == true)
    #expect(captures[0]["value"] == nil)
  }

  @Test func aBuiltInCallCannotClaimAFakeDeclarationBinding() throws {
    let snapshot = try snapshot("Use cos with two.")
    let evidence = snapshot.evidence()
    let candidate = SuggestionCandidate(
      id: "C1", edits: [SuggestionEdit(target: "T1", replacement: "cos(2)")],
      bindings: [SuggestionBinding(symbol: "cos", source: "F99")],
      literals: [
        SuggestionLiteral(
          text: "2", evidence: try #require(evidence.first { $0.text == "two" }?.handle))
      ],
      relations: [
        SuggestionRelation(
          rule: "interpretation",
          evidence: try #require(evidence.first { $0.kind == "relation" }?.handle))
      ],
      assumptions: [], summary: "Apply the built-in function.")
    #expect(throws: AssistanceValidationFailure.self) {
      try AssistanceCandidateChecker.check(candidate, against: snapshot)
    }
  }

  @Test func ordinaryEvaluationRetainsTheLocalOriginWhenItShadowsAnImportedName() throws {
    let inherited = try SheetDefinitions(source: "factor = 7", context: sheetContext())
    var calculator = SheetCalculator(definitions: inherited)
    let exported = try calculator.evaluate(
      SheetSource("factor = 11\nf(x) = x * factor"), context: sheetContext()
    ).definitions
    let snapshot = try snapshot("Use f with two.", definitions: exported)
    let records = try function(snapshot, name: "f")
    let captures = try #require(records[0]["captures"] as? [[String: Any]])
    #expect(captures[0]["source"] as? String == "factor = 11")
    #expect((captures[0]["origin"] as? String)?.hasPrefix("source:") == true)
    #expect(
      try AssistanceCandidateChecker.check(candidate("f(2)", snapshot: snapshot), against: snapshot)
        .result == .number(.integer(IntegerValue(22))))
  }

}
