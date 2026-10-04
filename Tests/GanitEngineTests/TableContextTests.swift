import Foundation
import Testing

@testable import GanitEngine

/// Implementation corpus for M2 task 4: table formulas reuse the ordinary
/// engine with the scope captured at the table entry (variables, custom
/// functions, manual rates, custom units and earlier line outcomes), read
/// one context per generation, carry provenance through dependencies and
/// diagnose unsupported syntax explicitly.
@Suite struct TableContextTests {
  private static let rates: CurrencyRates = {
    // 1 EUR = 1.25 USD = 90 INR: $10 → €8 exactly.
    try! CurrencyRates(
      unitsPerEuro: ["USD": "1.25", "INR": "90"], observationDate: "1970-01-01",
      retrievedAt: Date(timeIntervalSince1970: 0))
  }()

  private func context(rates: CurrencyRates = Self.rates) throws -> EvaluationContext {
    try sheetContext().with(rates)
  }

  /// The scope an ordinary sheet's lines give a table placed below them.
  private func scope(
    _ source: String, table: TableModel, context: EvaluationContext,
    tableLines: IndexSet = []
  ) throws -> TableFormulaScope {
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(SheetSource(source), context: context)
    var scope = TableFormulaScope(
      current: table, visible: [], inherited: [:],
      functions: evaluation.definitions.functions,
      units: .resolving(evaluation.definitions.units))
    scope.tableLines = tableLines
    for (index, line) in evaluation.lines.enumerated() {
      let number = index + 1
      if !line.rateUses.isEmpty {
        scope.lineProvenance[number] = TableCellProvenance(rateUses: line.rateUses)
      }
      switch line.result {
      case nil: scope.lines.append(.none)
      case .value(let value):
        scope.lines.append(.value(value))
        if let name = line.declaredVariableName { scope.inherited[name] = .some(value) }
      case .syntaxFailure, .evaluationFailure:
        scope.lines.append(.failure(lines: line.failureOriginLineNumbers))
        if let name = line.declaredVariableName { scope.inherited[name] = .some(nil) }
      }
    }
    return scope
  }

  private func table(_ inputs: [[String]], name: String = "Items") -> TableModel {
    let columns = inputs.map(\.count).max() ?? 1
    var table = TableModel.creating(
      name: name, headers: (0..<columns).map { ("Field\($0)", TableInputPolicy.value) },
      rowCount: inputs.count)
    for (row, sources) in inputs.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(row: table.rows[row], column: table.columns[column].id, source: source))
      }
    }
    return table
  }

  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  private func calculate(
    _ table: TableModel, scope: TableFormulaScope? = nil, context: EvaluationContext? = nil,
    earlier: [TableID: TableCalculationSnapshot] = [:]
  ) throws -> TableCalculationSnapshot {
    try TableCalculator().calculate(
      table, scope: scope ?? TableFormulaScope(current: table, visible: [], inherited: [:]),
      context: try context ?? self.context(), earlier: earlier)
  }

  /// The answer an ordinary sheet gives its last line.
  private func ordinary(_ source: String, context: EvaluationContext? = nil) throws
    -> (result: TableCellResult, rateUses: Set<CurrencyRateUse>)
  {
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(
      SheetSource(source), context: try context ?? self.context())
    let line = try #require(evaluation.lines.last)
    guard case .value(let value) = line.result else {
      Issue.record("ordinary \(source) failed: \(String(describing: line.result))")
      return (.blank, [])
    }
    return (.scalar(value), line.rateUses)
  }

  private func failure(_ snapshot: TableCalculationSnapshot, _ address: TableCellAddress)
    -> TableCalculationFailure?
  {
    if case .failure(let failure) = snapshot.result(at: address) { return failure }
    return nil
  }

  private func text(_ source: String, _ range: SourceRange?) -> Substring? {
    range?.text(in: source)
  }

  // MARK: - Exact arithmetic and conversions match ordinary lines

  @Test func tableFormulasMatchOrdinaryLines() throws {
    let cases: [(inputs: [String], formula: String, ordinary: String)] = [
      (["0.1", "0.2"], "=A2 + B2", "0.1 + 0.2"),
      (["1", "3"], "=A2 / B2 * B2", "1 / 3 * 3"),
      (["$12.50", "3"], "=A2 * B2 - $0.75", "$12.50 * 3 - $0.75"),
      (["$10", ""], "=A2 in EUR", "$10 in EUR"),
      (["$10", "$5"], "=(A2 + B2) in INR", "($10 + $5) in INR"),
      (["2 m", "50 cm"], "=(A2 + B2) in cm", "(2 m + 50 cm) in cm"),
      (["5 km", "2 h"], "=A2 / B2 in m/s", "5 km / 2 h in m/s"),
      (["1000", "5%"], "=FV(A2, B2, 10)", "fv(1000, 5%, 10)"),
      (["1000", "5%"], "=pmt(A2, B2, 10)", "pmt(1000, 5%, 10)"),
      (["4", "9"], "=Median(A2, B2, 1) + STDEV(A2, B2)", "median(4, 9, 1) + stdev(4, 9)"),
      (["2", "3"], "=SQRT(A2) * Round(B2 / 2)", "sqrt(2) * round(3 / 2)"),
      (["2024-01-31", ""], "=A2 + 1 month", "2024-01-31 + 1 month"),
      (["2024-03-01", "2024-01-01"], "=A2 - B2", "2024-03-01 - 2024-01-01"),
      (["", ""], "=today + 3 days", "today + 3 days"),
      (["3", ""], "=A2 * pi", "3 * pi"),
    ]
    for (inputs, formula, source) in cases {
      let model = table([inputs + [formula]])
      let snapshot = try calculate(model)
      let expected = try ordinary(source)
      #expect(snapshot.result(at: address(model, 0, 2)) == expected.result, "\(formula)")
      #expect(snapshot.traces[address(model, 0, 2)]?.rateUses == expected.rateUses, "\(formula)")
    }
  }

  @Test func mixedCurrenciesNeedExplicitConversion() throws {
    // Ordinary lines add `$10 + €5` at the rates; table formulas never
    // convert implicitly, in scalar arithmetic or range reductions.
    let model = table([
      ["$10", "€5", "=A2 + B2", "=sum(A2:B2)", "=A2 in EUR + B2", "=B2 - A2"]
    ])
    let snapshot = try calculate(model)
    #expect(failure(snapshot, address(model, 0, 2))?.engineError?.code == .mixedCurrencies)
    #expect(failure(snapshot, address(model, 0, 3))?.engineError?.code == .mixedCurrencies)
    #expect(snapshot.result(at: address(model, 0, 4)) == (try ordinary("$10 in EUR + €5")).result)
    #expect(failure(snapshot, address(model, 0, 5))?.engineError?.code == .mixedCurrencies)
    // An ordinary line converts the same operands at the rates.
    #expect((try ordinary("$10 + €5")).rateUses == [.reference])
    #expect(snapshot.provenance[address(model, 0, 2)] == nil)
  }

  @Test func storedValuesAreNeverRounded() throws {
    // A reader sees the exact stored value, not a formatted one.
    let model = table([["=1/3", "=A2 * 3", "=sum(A:A) * 3", "=A2 + 0"]])
    let snapshot = try calculate(model)
    #expect(
      snapshot.result(at: address(model, 0, 1)) == .scalar(.number(.integer(IntegerValue(1)))))
    #expect(
      snapshot.result(at: address(model, 0, 2)) == .scalar(.number(.integer(IntegerValue(1)))))
    #expect(snapshot.result(at: address(model, 0, 3)) == (try ordinary("1/3")).result)
  }

  // MARK: - Captured scope

  @Test func inheritedCustomFunctionsKeepTheirClosures() throws {
    let model = table([
      ["21", "=double(A2)", "=DOUBLE(A2) + 1", "=scaled(A2)", "=double(scaled(1))"]
    ])
    let context = try context()
    let captured = try scope(
      "rate = 3\ndouble(x) = x * 2\nscaled(x) = x * rate\nrate = 100", table: model,
      context: context)
    let snapshot = try calculate(model, scope: captured, context: context)
    let number = { (value: Int) in TableCellResult.scalar(.number(.integer(IntegerValue(value)))) }
    #expect(snapshot.result(at: address(model, 0, 1)) == number(42))
    #expect(snapshot.result(at: address(model, 0, 2)) == number(43))
    // `scaled` captured `rate = 3` where it was defined.
    #expect(snapshot.result(at: address(model, 0, 3)) == number(63))
    #expect(snapshot.result(at: address(model, 0, 4)) == number(6))
  }

  @Test func customFunctionsOverRangesAreUnsupportedRangeOperations() throws {
    let model = table([["1", "=double(A:A)", "=Sum(A2:A3)", "=SUM(A:A)", "=sum(A:A)"], ["2"]])
    let context = try context()
    let captured = try scope("double(x) = x * 2\nSum(x) = x * 3", table: model, context: context)
    let snapshot = try calculate(model, scope: captured, context: context)
    for column in 1...3 {
      #expect(failure(snapshot, address(model, 0, column))?.code == .unsupportedRangeOperation)
    }
    // Exact `sum` resolves as ordinary dispatch does: the built-in.
    #expect(
      snapshot.result(at: address(model, 0, 4)) == .scalar(.number(.integer(IntegerValue(3)))))
  }

  @Test func manualRatesAndCustomUnitsFromAboveApply() throws {
    let model = table([["$10", "=A2 in INR", "2 bag", "=C2 in kg", "=(3 * 1 bag) in kg"]])
    let context = try context(rates: .none)
    let captured = try scope("1 USD = 80 INR\n1 bag = 25 kg", table: model, context: context)
    var withRate = captured
    withRate.rates[CurrencyPair(from: "USD", to: "INR")] = .integer(IntegerValue(80))
    let snapshot = try calculate(model, scope: withRate, context: context)
    let expected = try ordinary("1 USD = 80 INR\n$10 in INR", context: context)
    #expect(snapshot.result(at: address(model, 0, 1)) == expected.result)
    #expect(snapshot.traces[address(model, 0, 1)]?.rateUses == [.manual])
    #expect(snapshot.provenance[address(model, 0, 1)]?.rateUses == [.manual])
    let bags = try ordinary("1 bag = 25 kg\n2 bag in kg", context: context)
    #expect(snapshot.result(at: address(model, 0, 3)) == bags.result)
    #expect(
      snapshot.result(at: address(model, 0, 4))
        == (try ordinary("1 bag = 25 kg\n(3 * 1 bag) in kg", context: context)).result)
    // Without the scope's rate and units, both fail rather than guess.
    let bare = try calculate(model, context: context)
    #expect(failure(bare, address(model, 0, 1)) != nil)
    #expect(failure(bare, address(model, 0, 2))?.code == .invalidLiteral)
  }

  // MARK: - Line references

  @Test func lineReferencesReadEarlierProseOnly() throws {
    // Lines 1–3 are prose; the block occupies lines 4–8 (zero-based 3..<8).
    let model = table([
      ["=@1 * 2", "=line 3 + @1", "=@2", "=@4", "=@8 + 1", "=@9", "=line 40", "=@0"]
    ])
    let context = try context()
    let captured = try scope(
      "7\n# note\n5", table: model, context: context, tableLines: IndexSet(integersIn: 3..<8))
    let snapshot = try calculate(model, scope: captured, context: context)
    let number = { (value: Int) in TableCellResult.scalar(.number(.integer(IntegerValue(value)))) }
    #expect(snapshot.result(at: address(model, 0, 0)) == number(14))
    #expect(snapshot.result(at: address(model, 0, 1)) == number(12))
    // A comment line has no answer: the ordinary invalid reference.
    #expect(failure(snapshot, address(model, 0, 2))?.engineError?.code == .invalidReference)
    for column in [3, 4] {
      let failed = failure(snapshot, address(model, 0, column))
      #expect(failed?.code == .reference)
      #expect(failed?.referenceDiagnostic?.code == .tableLineReference)
    }
    for column in [5, 6] {
      #expect(
        failure(snapshot, address(model, 0, column))?.referenceDiagnostic?.code
          == .laterLineReference)
    }
    #expect(failure(snapshot, address(model, 0, 7))?.engineError?.code == .invalidReference)
  }

  @Test func lineReferencesIntoAnEarlierTableFail() throws {
    // Line 1 prose, lines 2–4 an earlier table, line 5 prose, lines 6–9
    // this table, line 10 onward later.
    let model = table([["=@1", "=@3", "=@5", "=@7", "=@10"]])
    var captured = TableFormulaScope(current: model, visible: [], inherited: [:])
    captured.lines.append(.value(.number(.integer(IntegerValue(7)))))
    for _ in 0..<3 { captured.lines.append(.none) }
    captured.lines.append(.value(.number(.integer(IntegerValue(5)))))
    captured.tableLines = IndexSet(integersIn: 1..<4)
    captured.tableLines.insert(integersIn: 5..<9)
    let snapshot = try calculate(model, scope: captured)
    #expect(
      snapshot.result(at: address(model, 0, 0)) == .scalar(.number(.integer(IntegerValue(7)))))
    #expect(
      snapshot.result(at: address(model, 0, 2)) == .scalar(.number(.integer(IntegerValue(5)))))
    for column in [1, 3] {
      #expect(
        failure(snapshot, address(model, 0, column))?.referenceDiagnostic?.code
          == .tableLineReference, "column \(column)")
    }
    #expect(
      failure(snapshot, address(model, 0, 4))?.referenceDiagnostic?.code == .laterLineReference)
  }

  @Test func lineReferenceToAFailedLineIsAnInheritedFailure() throws {
    let model = table([["=@1 + 1", "=@2 + 1"]])
    let context = try context()
    let captured = try scope("1 / 0\n4", table: model, context: context)
    let snapshot = try calculate(model, scope: captured, context: context)
    let failed = failure(snapshot, address(model, 0, 0))
    #expect(failed?.referenceDiagnostic?.code == .inheritedFailure)
    #expect(text("=@1 + 1", failed?.sourceRange) == "@1")
    #expect(
      snapshot.result(at: address(model, 0, 1)) == .scalar(.number(.integer(IntegerValue(5)))))
  }

  @Test func ownScopeErrorsOutrankBlockedInputs() throws {
    let model = table([["=1/0", "=@9 + A2", "=frobnicate(A2)", "=IF(A2, 1, 2)", "=A2 + 1"]])
    let snapshot = try calculate(model)
    #expect(
      failure(snapshot, address(model, 0, 1))?.referenceDiagnostic?.code == .laterLineReference)
    let unknown = failure(snapshot, address(model, 0, 2))
    #expect(unknown?.code == .evaluation)
    #expect(unknown?.engineError?.code == .unknownFunction)
    #expect(text("=frobnicate(A2)", unknown?.sourceRange) == "frobnicate")
    #expect(failure(snapshot, address(model, 0, 3))?.code == .unsupported)
    #expect(failure(snapshot, address(model, 0, 4))?.code == .blocked)
  }

  // MARK: - Unsupported syntax

  @Test func assistantPromptsAreNeverAsked() throws {
    let prompt = AssistantPrompt([.text("10 kg of water in ml")])
    let answered = try context().with(
      assistantAnswers: [prompt: .value(.number(.integer(IntegerValue(10_000))))])
    let model = table([
      [
        "=ask_assistant(10 kg of water in ml)", "=2 * ask_assistant(10 kg of water in ml)",
        "=ASK_ASSISTANT(10 kg of water in ml)",
      ]
    ])
    for context in [try context(), answered] {
      let snapshot = try calculate(model, context: context)
      for column in 0..<3 {
        let failed = failure(snapshot, address(model, 0, column))
        #expect(failed?.code == .unsupported)
        #expect(failed?.referenceDiagnostic?.code == .assistantPrompt)
        #expect(snapshot.traces[address(model, 0, column)] == nil)
      }
    }
  }

  @Test func deferredFunctionsAndComparisonsAreUnsupported() throws {
    let functions = [
      "=if(A2, 1, 2)", "=IF(A2 > 1, 1, 2)", "=IfError(A2, 0)", "=vlookup(A2, A:A, 1)",
      "=index(A:A, 1)", "=concat(A2, A3)", "=LEFT(A2, 1)", "=sumif(A:A, 1)", "=rand()",
      "=and(A2, A3)",
    ]
    let comparisons: [(String, Substring)] = [
      ("=A2 > 1", ">"), ("=A2 < 1", "<"), ("=A2 = 1", "="), ("=A2 <> 1", "<>"),
      ("=A2 >= 1", ">="), ("=A2 != 1", "!="), ("=A2 ≠ 1", "≠"), ("=A2 == 1", "=="),
    ]
    let model = table([["2"] + functions + comparisons.map(\.0), ["3"]])
    let snapshot = try calculate(model)
    for (offset, formula) in functions.enumerated() {
      let failed = failure(snapshot, address(model, 0, offset + 1))
      #expect(failed?.code == .unsupported, "\(formula)")
      #expect(failed?.referenceDiagnostic?.code == .unsupportedFunction, "\(formula)")
      #expect(text(formula, failed?.sourceRange)?.first?.isLetter == true, "\(formula)")
    }
    for (offset, (formula, spelling)) in comparisons.enumerated() {
      let failed = failure(snapshot, address(model, 0, functions.count + offset + 1))
      #expect(failed?.referenceDiagnostic?.code == .unsupportedComparison, "\(formula)")
      #expect(text(formula, failed?.sourceRange) == spelling, "\(formula)")
    }
  }

  @Test func anEarlierLexingErrorStaysASyntaxError() throws {
    let model = table([["=#1 > 2", "=1 > #2", "=2 ⩽ 3", "=2 ＞ 3"]])
    let snapshot = try calculate(model)
    #expect(failure(snapshot, address(model, 0, 0))?.code == .syntax)
    #expect(
      failure(snapshot, address(model, 0, 1))?.referenceDiagnostic?.code == .unsupportedComparison)
    for column in [2, 3] {
      #expect(
        failure(snapshot, address(model, 0, column))?.referenceDiagnostic?.code
          == .unsupportedComparison, "column \(column)")
    }
  }

  @Test func visibleCustomFunctionKeepsADeferredName() throws {
    let model = table([["4", "=text(A2)", "=Text(A2) + 1"]])
    let context = try context()
    let captured = try scope("text(x) = x * 2", table: model, context: context)
    let snapshot = try calculate(model, scope: captured, context: context)
    #expect(
      snapshot.result(at: address(model, 0, 1)) == .scalar(.number(.integer(IntegerValue(8)))))
    #expect(
      snapshot.result(at: address(model, 0, 2)) == .scalar(.number(.integer(IntegerValue(9)))))
  }

  @Test func ordinarySyntaxIsUnchangedOutsideTables() throws {
    // Only table formulas diagnose these; ordinary parses keep their errors.
    let syntax = try TableFormulaSyntax.discover("if(1, 2, 3) > 1", tableFormula: false)
    let parsing = try syntax.parse(context: sheetContext())
    #expect(parsing.expression == nil)
    #expect(parsing.diagnostics.first?.code == .unexpectedCharacter)
  }

  // MARK: - One context and provenance

  @Test func oneGenerationReadsOneClockAndCarriesItsProvenance() throws {
    let model = table([
      ["=today", "=A2 + 1 day", "=max(A:A)", "=C2", "5", "=now"],
      ["=today", "", "", "", "=E2 * 2", ""],
    ])
    let context = try context()
    let snapshot = try calculate(model, context: context)
    #expect(snapshot.result(at: address(model, 0, 0)) == snapshot.result(at: address(model, 1, 0)))
    #expect(snapshot.result(at: address(model, 0, 1)) == (try ordinary("today + 1 day")).result)
    // The reader's own trace read no clock; its provenance carries the input's.
    #expect(snapshot.traces[address(model, 0, 1)]?.clock == nil)
    #expect(snapshot.provenance[address(model, 0, 1)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 2)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 3)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 4)] == nil)
    #expect(snapshot.provenance[address(model, 1, 4)] == nil)
    #expect(snapshot.combinedProvenance.clock == .second)
    #expect(snapshot.nextRecalculation == Date(timeIntervalSince1970: 1))
    #expect(snapshot.context == context)
  }

  @Test func rateProvenanceFlowsThroughCellsRangesAndEarlierTables() throws {
    let rates = table([["$10", "=A2 in EUR"], ["$5", "=A3 in EUR"]], name: "Rates")
    let context = try context()
    let earlier = try calculate(rates, context: context)
    let model = table([["=Rates!B2 * 2", "=sum(Rates!B:B)", "=A2 + B2", "=sum(Rates!A:A)"]])
    let snapshot = try calculate(
      model, scope: TableFormulaScope(current: model, visible: [rates], inherited: [:]),
      context: context, earlier: [rates.id: earlier])
    #expect(earlier.provenance[address(rates, 0, 1)]?.rateUses == [.reference])
    #expect(snapshot.result(at: address(model, 0, 0)) == (try ordinary("($10 in EUR) * 2")).result)
    for column in 0..<3 {
      #expect(snapshot.traces[address(model, 0, column)]?.rateUses == [], "column \(column)")
      #expect(
        snapshot.provenance[address(model, 0, column)]?.rateUses == [.reference],
        "column \(column)")
    }
    #expect(snapshot.provenance[address(model, 0, 3)] == nil)
    #expect(snapshot.combinedProvenance.rateUses == [.reference])
    #expect(snapshot.combinedProvenance.clock == nil)
    #expect(snapshot.nextRecalculation == nil)
  }

  @Test func inheritedVariableAndLineProvenanceIsCarried() throws {
    let model = table([
      ["=sheet[due] + 1 day", "=Due", "=@1 + 1 day", "=@2 * 2", "=fv(1000, 5%, 1)"]
    ])
    let context = try context()
    var captured = try scope("due = today\n$10 in EUR", table: model, context: context)
    captured.variableProvenance["due"] = TableCellProvenance(clock: .day)
    captured.lineProvenance[1] = TableCellProvenance(clock: .day)
    let snapshot = try calculate(model, scope: captured, context: context)
    #expect(snapshot.provenance[address(model, 0, 0)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 1)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 2)]?.clock == .day)
    #expect(snapshot.provenance[address(model, 0, 3)]?.rateUses == [.reference])
    #expect(snapshot.provenance[address(model, 0, 4)]?.financeUses == [.futureValue])
    #expect(snapshot.nextRecalculation == Date(timeIntervalSince1970: 86_400))
  }

  @Test func customFunctionClosuresCarryTheirCapturedProvenance() throws {
    let model = table([["=f(1)", "=Scaled(2)", "=Later(1)", "=A2 + 1 day", "=k(3)"]])
    let context = try context()
    var captured = try scope(
      "due = today\nrate = $10 in EUR\nf(x) = due + x * 1 day\nscaled(x) = rate * x"
        + "\nlater(x) = f(x)\nk(x) = x * 2",
      table: model, context: context)
    let variables = [
      "due": TableCellProvenance(clock: .day), "rate": TableCellProvenance(rateUses: [.reference]),
    ]
    captured.variableProvenance = variables
    captured.functionProvenance = TableFormulaScope.functionProvenance(
      captured.functions, variableProvenance: variables)
    // The per-definition form agrees for `later`, which captured `f`.
    let later = try #require(captured.functions["later"])
    #expect(
      TableFormulaScope.functionProvenance(
        of: later, variableProvenance: variables, functionProvenance: captured.functionProvenance)
        == TableCellProvenance(clock: .day))
    let snapshot = try calculate(model, scope: captured, context: context)
    #expect(snapshot.traces[address(model, 0, 0)]?.clock == nil)
    for column in [0, 2, 3] {
      #expect(snapshot.provenance[address(model, 0, column)]?.clock == .day, "column \(column)")
    }
    #expect(snapshot.provenance[address(model, 0, 1)]?.rateUses == [.reference])
    #expect(snapshot.provenance[address(model, 0, 4)] == nil)
    #expect(snapshot.nextRecalculation == Date(timeIntervalSince1970: 86_400))
    #expect(!snapshot.isCurrent(in: context.at(Date(timeIntervalSince1970: 86_400))))
  }

  /// `f1` captures `due`; `fk` captures `f(k-1)` and `f(k-2)`. As a tree the
  /// closures grow like Fibonacci numbers; the batch helper stays linear.
  private func fibonacciFunctions(_ count: Int) throws -> [String: CustomFunction] {
    let body = try #require(Parser(source: "1").parse().expression)
    let due = EngineValue.number(.integer(IntegerValue(0)))
    var functions: [String: CustomFunction] = [:]
    for k in 1...count {
      var captured: [String: CustomFunction] = [:]
      for previous in [k - 1, k - 2] where previous >= 1 {
        captured["f\(previous)"] = functions["f\(previous)"]
      }
      functions["f\(k)"] = CustomFunction(
        name: "f\(k)", parameters: ["x"], body: body,
        variables: k == 1 ? ["due": due] : [:], functions: captured)
    }
    return functions
  }

  @Test func batchFunctionProvenanceIsLinearInSharedClosures() throws {
    let variables = ["due": TableCellProvenance(clock: .day)]
    let forty = TableFormulaScope.functionProvenance(
      try fibonacciFunctions(40), variableProvenance: variables)
    #expect(forty.count == 40)
    #expect(forty["f40"] == TableCellProvenance(clock: .day))
    #expect(forty["f2"] == TableCellProvenance(clock: .day))
    func seconds(_ count: Int) throws -> Double {
      let functions = try fibonacciFunctions(count)
      var fastest = Double.infinity
      for _ in 0..<2 {
        let start = ContinuousClock.now
        _ = TableFormulaScope.functionProvenance(functions, variableProvenance: variables)
        let elapsed = (ContinuousClock.now - start).components
        fastest = min(fastest, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
      }
      return fastest
    }
    let small = try seconds(500)
    let large = try seconds(2_000)
    #expect(large < max(small, 0.05) * 9, "500→2000: \(small)s → \(large)s")
  }

  @Test func earlierTablesFromAnotherGenerationContextAreNotRead() throws {
    let rates = table([["$10", "=A2 in EUR", "=today"]], name: "Rates")
    let model = table([["=Rates!A2 * 2", "=Rates!B2 * 2"]])
    let scope = TableFormulaScope(current: model, visible: [rates], inherited: [:])
    let context = try context()
    // Different rates: not this generation's results.
    let unrated = try calculate(rates, context: try self.context(rates: .none))
    let stale = try calculate(model, scope: scope, context: context, earlier: [rates.id: unrated])
    #expect(failure(stale, address(model, 0, 0))?.referenceDiagnostic?.code == .staleTable)
    // The same context later the same day is current for a `.day` result,
    // but not on the next day.
    let earlier = try calculate(rates, context: context)
    let later = context.at(Date(timeIntervalSince1970: 3_600))
    let sameDay = try calculate(model, scope: scope, context: later, earlier: [rates.id: earlier])
    #expect(sameDay.result(at: address(model, 0, 0)) == (try ordinary("$10 * 2")).result)
    let nextDay = context.at(Date(timeIntervalSince1970: 86_400))
    let tomorrow = try calculate(
      model, scope: scope, context: nextDay, earlier: [rates.id: earlier])
    #expect(failure(tomorrow, address(model, 0, 0))?.referenceDiagnostic?.code == .staleTable)
    // A table this generation has not calculated at all is still missing.
    let missing = try calculate(model, scope: scope, context: context)
    #expect(failure(missing, address(model, 0, 0))?.referenceDiagnostic?.code == .missingTable)
  }

  @Test func provenanceStaysLinearForLargeTables() throws {
    // 4,000 cells: one clock column read by a running reader per row and a
    // whole-column reduction; members are visited once per range node.
    let rows = 2_000
    let model = table((0..<rows).map { ["=today + \($0) days", "=max(A:A)"] })
    let snapshot = try calculate(model)
    #expect(snapshot.rangeCellVisits == rows)
    #expect(snapshot.provenance.count == 2 * rows)
    #expect(snapshot.provenance[address(model, rows - 1, 1)]?.clock == .day)
  }
}
