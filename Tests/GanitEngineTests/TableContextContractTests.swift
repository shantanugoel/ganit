import Foundation
import Testing

@testable import GanitEngine

/// Task-4 contract evidence, written from the plan ("Document and scope",
/// "Cell input and values", "Addressing", "Architecture and ownership") and
/// ADR 0016 rather than from the implementation: table formulas reuse the
/// ordinary engine's arithmetic, conversions, functions (including inherited
/// custom functions), one clock and rate snapshot per generation, and
/// provenance; unsupported syntax fails explicitly with no assistant
/// fallback. Expected values come from the ordinary engine or an ordinary
/// sheet evaluated with the same context.
@Suite struct TableContextContractTests {
  // MARK: - Fixtures

  private static let rates: CurrencyRates = {
    // 1 EUR = 1.25 USD = 90 INR, so $10 → €8 and $5 → €4 exactly.
    try! CurrencyRates(
      unitsPerEuro: ["USD": "1.25", "INR": "90"], observationDate: "1970-01-01",
      retrievedAt: Date(timeIntervalSince1970: 0))
  }()

  /// The fixed clock (1970-01-01T00:00:00Z) with a rate snapshot.
  private func context(rates: CurrencyRates = Self.rates) throws -> EvaluationContext {
    try sheetContext().with(rates)
  }

  /// What a table captures from the ordinary prose above it: variables
  /// (a failed line keeps its name with no value), custom functions and the
  /// physical-line outcomes `@N` reads.
  private struct Prose {
    var variables: [String: EngineValue?] = [:]
    var functions: [String: CustomFunction] = [:]
    var lines = LineOutcomes()
    /// Manual rates declared above, e.g. `1 USD = 80 INR`. `SheetDefinitions`
    /// does not export them, so tests state them alongside the source.
    var rates: [CurrencyPair: NumericValue] = [:]
    var units: [CustomUnit] = []
    var variableProvenance: [String: TableCellProvenance] = [:]
    var lineProvenance: [Int: TableCellProvenance] = [:]
    var evaluation: SheetEvaluation?
  }

  private func prose(_ source: String, context: EvaluationContext) throws -> Prose {
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(SheetSource(source), context: context)
    var prose = Prose(evaluation: evaluation)
    prose.functions = evaluation.definitions.functions
    prose.units = evaluation.definitions.units
    for (index, line) in evaluation.lines.enumerated() {
      let provenance = TableCellProvenance(
        clock: nil, rateUses: line.rateUses, financeUses: line.financeUses)
      if !provenance.isEmpty {
        prose.lineProvenance[index + 1] = provenance
        if let name = line.declaredVariableName { prose.variableProvenance[name] = provenance }
      }
      switch line.result {
      case nil:
        prose.lines.append(.none)
      case .value(let value):
        prose.lines.append(.value(value))
        if let name = line.declaredVariableName { prose.variables[name] = .some(value) }
      case .syntaxFailure, .evaluationFailure:
        prose.lines.append(.failure(lines: line.failureOriginLineNumbers))
        if let name = line.declaredVariableName { prose.variables[name] = .some(nil) }
      }
    }
    return prose
  }

  private func table(_ inputs: [[String]], name: String = "Items", headers: [String]? = nil)
    -> TableModel
  {
    let columns = max(inputs.map(\.count).max() ?? 1, headers?.count ?? 0)
    var table = TableModel.creating(
      name: name,
      headers: (0..<columns).map { (headers?[$0] ?? "Field\($0)", TableInputPolicy.value) },
      rowCount: inputs.count)
    for (row, sources) in inputs.enumerated() {
      for (column, source) in sources.enumerated() where !source.isEmpty {
        table.cells.append(
          TableCell(row: table.rows[row], column: table.columns[column].id, source: source))
      }
    }
    return table
  }

  /// `row` is a zero-based data row index (A1 row = row + 2).
  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  /// The single seam onto the task-4 scope API: inherited variables, custom
  /// functions visible at the table's position and earlier prose outcomes.
  private func calculate(
    _ table: TableModel, prose: Prose = Prose(), context: EvaluationContext? = nil
  ) throws -> TableCalculationSnapshot {
    let calculator = TableCalculator()
    var scope = TableFormulaScope(current: table, visible: [], inherited: prose.variables)
    scope.functions = prose.functions
    scope.rates = prose.rates
    scope.units = .resolving(prose.units)
    scope.lines = prose.lines
    // The table block starts on the physical line right after the prose and
    // spans opener, header, data rows and closer (zero-based).
    let opener = prose.evaluation?.lines.count ?? 0
    scope.tableLines = IndexSet(integersIn: opener..<(opener + table.rows.count + 3))
    scope.variableProvenance = prose.variableProvenance
    scope.lineProvenance = prose.lineProvenance
    scope.functionProvenance = TableFormulaScope.functionProvenance(
      prose.functions, variableProvenance: prose.variableProvenance)
    return try calculator.calculate(table, scope: scope, context: try context ?? self.context())
  }

  /// The ordinary engine's value and trace for one expression.
  private func ordinary(
    _ source: String, context: EvaluationContext? = nil, prose: Prose = Prose()
  ) throws -> (result: CalculationResult, trace: EvaluationTrace) {
    let context = try context ?? self.context()
    let kinds = prose.variables.mapValues { $0?.kind ?? .number }
    let parsing = CalculationEngine().parse(source, context: context, variables: kinds)
    guard let expression = parsing.expression else {
      return (.syntaxFailure(parsing.diagnostics), EvaluationTrace())
    }
    return CalculationEngine().evaluate(
      expression, context: context, variables: prose.variables, lines: prose.lines,
      functions: prose.functions)
  }

  private func ordinaryValue(
    _ source: String, context: EvaluationContext? = nil, prose: Prose = Prose(),
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) throws -> TableCellResult {
    let result = try ordinary(source, context: context, prose: prose).result
    guard case .value(let value) = result else {
      Issue.record("Ordinary \(source) failed: \(result)", sourceLocation: sourceLocation)
      return .blank
    }
    return .scalar(value)
  }

  @discardableResult
  private func failure(
    _ snapshot: TableCalculationSnapshot, _ address: TableCellAddress,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) -> TableCalculationFailure? {
    guard case .failure(let failure) = snapshot.result(at: address) else {
      Issue.record(
        "Expected an explicit failure, got \(String(describing: snapshot.result(at: address)))",
        sourceLocation: sourceLocation)
      return nil
    }
    return failure
  }

  private func scalar(
    _ snapshot: TableCalculationSnapshot, _ address: TableCellAddress,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) -> EngineValue? {
    guard case .scalar(let value) = snapshot.result(at: address) else {
      Issue.record(
        "Expected a scalar, got \(String(describing: snapshot.result(at: address)))",
        sourceLocation: sourceLocation)
      return nil
    }
    return value
  }

  /// The provenance a cell carries from its inputs plus its own evaluation.
  private func provenance(_ snapshot: TableCalculationSnapshot, _ address: TableCellAddress)
    -> TableCellProvenance
  {
    snapshot.provenance[address] ?? TableCellProvenance()
  }

  private func isApproximate(_ value: EngineValue?) -> Bool {
    if case .number(.approximate) = value { return true }
    return false
  }

  // MARK: - Exact arithmetic, money, conversions and functions

  @Test func exactDecimalArithmeticMatchesOrdinaryEngine() throws {
    let table = table([["0.1", "0.2", "=A2 + B2", "=A2 / 3", "=(A2 + B2) * 10 - 3"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("0.1 + 0.2")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("0.3")))
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("0.1 / 3")))
    #expect(
      snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("(0.1 + 0.2) * 10 - 3")))
    #expect(!isApproximate(scalar(snapshot, address(table, 0, 3))))
  }

  @Test func moneyArithmeticMatchesOrdinaryEngine() throws {
    let table = table([["$12.50", "3", "=A2 * B2", "=A2 / 4", "=A2 - $0.75"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("$12.50 * 3")))
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("$12.50 / 4")))
    #expect(snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("$12.50 - $0.75")))
  }

  @Test func explicitCurrencyConversionUsesTheProvidedRateSnapshot() throws {
    let table = table([["$10", "=A2 in EUR", "=A2 in INR"]])
    let snapshot = try calculate(table)
    let euro = try ordinary("$10 in EUR")
    let rupee = try ordinary("$10 in INR")
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("$10 in EUR")))
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("€8.0")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("$10 in INR")))
    #expect(snapshot.traces[address(table, 0, 1)]?.rateUses == euro.trace.rateUses)
    #expect(snapshot.traces[address(table, 0, 2)]?.rateUses == rupee.trace.rateUses)
    #expect(euro.trace.rateUses == [.reference])

    // Without a snapshot the same conversion fails exactly as ordinarily.
    let unrated = try calculate(table, context: try context(rates: .none))
    let error = failure(unrated, address(table, 0, 1))?.engineError?.code
    guard
      case .evaluationFailure(let expected) = try ordinary(
        "$10 in EUR", context: try context(rates: .none)
      ).result
    else {
      Issue.record("Ordinary conversion without rates must fail")
      return
    }
    #expect(error == expected.code)
  }

  /// Literal reading of "require explicit currency conversion": a table
  /// never converts implicitly, even with a rate snapshot available. The
  /// ordinary engine converts `$10 + €5` implicitly when rates exist, so
  /// the scalar half of this test is flagged as an ambiguity.
  @Test func mixingCurrenciesNeverConvertsImplicitly() throws {
    let table = table([
      ["$10", "€5", "=A2 + B2", "=sum(A:B)", "=sum(A2:B2)"],
      ["$5", "€2", "", "", ""],
    ])
    let snapshot = try calculate(table)
    // Range reductions: explicit conversion required.
    failure(snapshot, address(table, 0, 3))
    failure(snapshot, address(table, 0, 4))
    // Scalar mixed arithmetic (ambiguity: ordinary sheets convert implicitly).
    failure(snapshot, address(table, 0, 2))
  }

  @Test func explicitConversionBeforeAggregationSucceeds() throws {
    let table = table([
      ["$10", "=A2 in EUR", "=sum(B:B)", "=sum(A:A) in EUR"],
      ["$5", "=A3 in EUR", "", ""],
    ])
    let snapshot = try calculate(table)
    #expect(
      snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("($10 in EUR) + ($5 in EUR)"))
    )
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("($10 + $5) in EUR")))
  }

  @Test func unitConversionsMatchOrdinaryEngine() throws {
    let table = table([["2 m", "=A2 in cm", "=(A2 * 3) in cm", "=A2 + 50 cm", "=A2 in kg"]])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("2 m in cm")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("(2 m * 3) in cm")))
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("2 m + 50 cm")))
    // A dimensional mismatch is the ordinary engine's error, not a value.
    guard case .evaluationFailure(let expected) = try ordinary("2 m in kg").result else {
      Issue.record("Ordinary dimensional mismatch must fail")
      return
    }
    #expect(failure(snapshot, address(table, 0, 4))?.engineError?.code == expected.code)
  }

  @Test func financeAndStatisticsFunctionsMatchOrdinaryEngine() throws {
    let table = table([
      [
        "1000", "5%", "10", "=fv(A2, B2, C2)", "=PV(A2, B2, C2)", "=Pmt(A2, B2, C2)",
        "=median(A2, C2, 4)", "=AVERAGE(A2, C2)", "=Sqrt(16) + ROUND(2.5)",
      ]
    ])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("fv(1000, 5%, 10)")))
    #expect(snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("pv(1000, 5%, 10)")))
    #expect(snapshot.result(at: address(table, 0, 5)) == (try ordinaryValue("pmt(1000, 5%, 10)")))
    #expect(snapshot.result(at: address(table, 0, 6)) == (try ordinaryValue("median(1000, 10, 4)")))
    #expect(snapshot.result(at: address(table, 0, 7)) == (try ordinaryValue("average(1000, 10)")))
    #expect(
      snapshot.result(at: address(table, 0, 8)) == (try ordinaryValue("sqrt(16) + round(2.5)")))
    // Finance provenance follows the ordinary trace.
    #expect(
      snapshot.traces[address(table, 0, 3)]?.financeUses
        == (try ordinary("fv(1000, 5%, 10)")).trace.financeUses)
    #expect(snapshot.traces[address(table, 0, 4)]?.financeUses == [.presentValue])
  }

  @Test func temporalArithmeticMatchesOrdinaryEngineWithTheFixedClock() throws {
    let table = table([
      ["2024-01-31", "=A2 + 1 month", "=today + 3 days", "=A2 - 2024-01-01", "=today"]
    ])
    let snapshot = try calculate(table)
    #expect(
      snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("2024-01-31 + 1 month")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("today + 3 days")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("1970-01-04")))
    #expect(
      snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("2024-01-31 - 2024-01-01")))
    #expect(snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("1970-01-01")))
    #expect(snapshot.traces[address(table, 0, 2)]?.clock == .day)
  }

  /// A manual rate declared above the table is part of its captured scope,
  /// as it is for ordinary lines below the declaration.
  @Test func manualRateDeclaredAboveIsUsedLikeOrdinaryLines() throws {
    let context = try context(rates: .none)
    var sheet = try prose("1 USD = 80 INR", context: context)
    sheet.rates[CurrencyPair(from: "USD", to: "INR")] = .integer(IntegerValue(80))
    let ordinarySheet = try prose("1 USD = 80 INR\n$10 in INR", context: context)
    let line = try #require(ordinarySheet.evaluation?.lines[1])
    guard case .value(let expected) = line.result else {
      Issue.record("Ordinary manual-rate conversion failed: \(String(describing: line.result))")
      return
    }
    let table = table([["$10", "=A2 in INR"]])
    let snapshot = try calculate(table, prose: sheet, context: context)
    #expect(snapshot.result(at: address(table, 0, 1)) == .scalar(expected))
    #expect(snapshot.traces[address(table, 0, 1)]?.rateUses == line.rateUses)
  }

  @Test func customUnitDeclaredAboveIsUsable() throws {
    let context = try context()
    let sheet = try prose("1 bag = 25 kg", context: context)
    let ordinarySheet = try prose("1 bag = 25 kg\n2 bag in kg", context: context)
    guard case .value(let expected) = ordinarySheet.evaluation?.lines[1].result else {
      Issue.record("Ordinary custom-unit conversion failed")
      return
    }
    let table = table([["2 bag", "=A2 in kg", "=(3 * 1 bag) in kg"]])
    let snapshot = try calculate(table, prose: sheet)
    #expect(snapshot.result(at: address(table, 0, 1)) == .scalar(expected))
    #expect(scalar(snapshot, address(table, 0, 2)) != nil)
  }

  // MARK: - Inherited custom functions

  @Test func inheritedCustomFunctionIsCallableInATableFormula() throws {
    let context = try context()
    let prose = try prose("rate = 3\ndouble(x) = x * 2\nscaled(x) = x * rate", context: context)
    #expect(prose.functions["double"] != nil)
    let table = table([
      ["21", "=double(A2)", "=DOUBLE(A2) + 1", "=scaled(A2)", "=double(double(A2))"]
    ])
    let snapshot = try calculate(table, prose: prose)
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("42")))
    // Ordinary dispatch looks custom names up case-insensitively too.
    #expect(
      snapshot.result(at: address(table, 0, 2))
        == (try ordinaryValue("DOUBLE(21) + 1", prose: prose)))
    // The body's own captured variables come with the function.
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("63")))
    #expect(snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("84")))
  }

  @Test func customFunctionDefinedAfterTheTableIsNotVisible() throws {
    // Only functions visible at the table's position are captured.
    let table = table([["21", "=double(A2)"]])
    let snapshot = try calculate(table)
    failure(snapshot, address(table, 0, 1))
  }

  /// Ordinary sheets accept `Sum(x) = …` as custom `sum`; `Sum(2)` calls it,
  /// while lowercase `sum(2, 3)` stays the built-in statistic. Tables must
  /// preserve that dispatch: case-insensitive built-in aliases never hijack
  /// a visible custom function.
  @Test func customFunctionNamesAreNotHijackedByBuiltIns() throws {
    let context = try context()
    let prose = try prose("Sum(x) = x * 3", context: context)
    #expect(prose.functions["sum"] != nil)
    let table = table([["2", "3", "=Sum(A2)", "=sum(A2, B2)", "=SUM(A2)"]])
    let snapshot = try calculate(table, prose: prose)
    #expect(
      snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("Sum(2)", prose: prose)))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("6")))
    #expect(
      snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("sum(2, 3)", prose: prose)))
    #expect(
      snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("SUM(2)", prose: prose)))
  }

  /// Literal reading: with custom `sum` visible, `SUM(…)` is the custom
  /// function (ordinary dispatch), and a custom function cannot take a
  /// range, so `SUM(A:A)` is an explicit diagnostic, never the built-in
  /// range total.
  @Test func uppercaseAggregateWithVisibleCustomNameIsNotTheBuiltIn() throws {
    let context = try context()
    let prose = try prose("Sum(x) = x * 3", context: context)
    let table = table([["2", "=SUM(A:A)", "=Sum(A2:A3)"], ["3", "", ""]])
    let snapshot = try calculate(table, prose: prose)
    let upper = failure(snapshot, address(table, 0, 1))
    #expect(upper?.code == .unsupportedRangeOperation)
    let mixed = failure(snapshot, address(table, 0, 2))
    #expect(mixed?.code == .unsupportedRangeOperation)
  }

  @Test func customFunctionOverARangeIsADiagnostic() throws {
    let context = try context()
    let prose = try prose("double(x) = x * 2", context: context)
    let table = table([
      ["1", "=double(A:A)", "=double(A2:A3)", "=double(Items[Field0])"], ["2", "", "", ""],
    ])
    let snapshot = try calculate(table, prose: prose)
    for column in 1...3 {
      #expect(failure(snapshot, address(table, 0, column))?.code == .unsupportedRangeOperation)
    }
  }

  // MARK: - One clock and one rate snapshot per generation

  @Test func oneGenerationReadsOneClock() throws {
    let rows = (0..<20).map { _ in ["=now", "=today", "=now + 0 seconds"] }
    let table = table(rows)
    let snapshot = try calculate(table)
    let now = try ordinaryValue("now")
    let today = try ordinaryValue("today")
    for row in 0..<rows.count {
      #expect(snapshot.result(at: address(table, row, 0)) == now)
      #expect(snapshot.result(at: address(table, row, 1)) == today)
      #expect(
        snapshot.result(at: address(table, row, 2)) == snapshot.result(at: address(table, 0, 0)))
    }
    #expect(snapshot.traces[address(table, 0, 0)]?.clock == .second)
    #expect(snapshot.traces[address(table, 0, 1)]?.clock == .day)
  }

  @Test func cellsAndRangeReductionsShareOneRateSnapshot() throws {
    let table = table([
      ["$10", "=A2 in EUR", "=sum(B:B)", "=sum(A:A) in EUR", "=C2 - D2"],
      ["$5", "=A3 in EUR", "", "", ""],
    ])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 2)) == snapshot.result(at: address(table, 0, 3)))
    #expect(snapshot.result(at: address(table, 0, 4)) == (try ordinaryValue("€8.0 - €8.0")))
    #expect(snapshot.traces[address(table, 0, 3)]?.rateUses == [.reference])
  }

  // MARK: - Provenance

  @Test func approximationProvenanceFlowsLikeOrdinaryLines() throws {
    let context = try context()
    let sheet = try prose("c = pi\nd = c * 2", context: context)
    let ordinaryReader = try #require(sheet.evaluation?.lines[1].result)
    guard case .value(let ordinaryValue) = ordinaryReader else {
      Issue.record("Ordinary reader failed")
      return
    }
    let table = table([["=pi", "=A2 * 2", "=B2 + 1"]])
    let snapshot = try calculate(table)
    let reader = scalar(snapshot, address(table, 0, 1))
    #expect(isApproximate(reader))
    #expect(reader == ordinaryValue)
    #expect(isApproximate(scalar(snapshot, address(table, 0, 2))))
  }

  /// Ordinary lines report only the rate uses of their own evaluation; a
  /// reader of a converted line has the converted value. The table reader
  /// must match that, and the converting cell keeps its own rate use.
  @Test func rateProvenanceFlowsLikeOrdinaryLines() throws {
    let context = try context()
    let sheet = try prose("converted = $10 in EUR\ntwice = converted * 2", context: context)
    let lines = try #require(sheet.evaluation?.lines)
    let table = table([["$10", "=A2 in EUR", "=B2 * 2"]])
    let snapshot = try calculate(table)
    #expect(snapshot.traces[address(table, 0, 1)]?.rateUses == lines[0].rateUses)
    guard case .value(let twice) = lines[1].result else {
      Issue.record("Ordinary reader failed")
      return
    }
    #expect(snapshot.result(at: address(table, 0, 2)) == .scalar(twice))
    let readerUses = snapshot.traces[address(table, 0, 2)]?.rateUses ?? []
    #expect(readerUses == lines[1].rateUses || readerUses == [.reference])
  }

  /// Plan: "Carry approximation, rounding, currency-rate and clock
  /// provenance through dependencies." A cell reading an inherited
  /// rate-converted variable, or a table cell that converted, reports the
  /// rate use (stronger than ordinary lines, which report only their own).
  @Test func rateProvenanceCarriesThroughDependencies() throws {
    let context = try context()
    let sheet = try prose("converted = $10 in EUR\n$5 in EUR", context: context)
    #expect(sheet.variableProvenance["converted"]?.rateUses == [.reference])
    let table = table([["$10", "=A2 in EUR", "=B2 * 2", "=sheet[converted] * 2", "=@2 + C2"]])
    let snapshot = try calculate(table, prose: sheet)
    for column in 2...4 {
      #expect(provenance(snapshot, address(table, 0, column)).rateUses == [.reference])
    }
  }

  @Test func inheritedApproximateVariableKeepsItsFlag() throws {
    let context = try context()
    let sheet = try prose("tau = 2 * pi", context: context)
    let table = table([["=sheet[tau] / 2", "=tau / 2"]])
    let snapshot = try calculate(table, prose: sheet)
    #expect(isApproximate(scalar(snapshot, address(table, 0, 0))))
    #expect(
      snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("tau / 2", prose: sheet)))
  }

  // MARK: - Line references

  @Test func lineReferenceReadsAnEarlierProseLine() throws {
    let context = try context()
    let sheet = try prose("7\n# heading\n5", context: context)
    let table = table([["3", "=@1 * A2", "=line 3 + @1", "=@1 in EUR * 0 + A2"]])
    let snapshot = try calculate(table, prose: sheet)
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("21")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("12")))
    failure(snapshot, address(table, 0, 3))
  }

  @Test func lineReferenceToAFailedProseLinePropagatesTheFailure() throws {
    let context = try context()
    let sheet = try prose("1 / 0\n4", context: context)
    let table = table([["=@1 + 1", "=@2 + 1"]])
    let snapshot = try calculate(table, prose: sheet)
    failure(snapshot, address(table, 0, 0))
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("5")))
  }

  /// Prose is lines 1–2; the table block then occupies lines 3 onward, so
  /// `@3` is the table's own opener and `@40` lies beyond the table.
  @Test func lineReferenceToLaterOrOwnLinesFails() throws {
    let context = try context()
    let sheet = try prose("7\n5", context: context)
    let table = table([["=@3", "=@4 + 1", "=@40", "=line 3"]])
    let snapshot = try calculate(table, prose: sheet)
    let expected: [TableFormulaDiagnostic.Code] = [
      .tableLineReference, .tableLineReference, .laterLineReference, .tableLineReference,
    ]
    for (column, code) in expected.enumerated() {
      #expect(failure(snapshot, address(table, 0, column))?.referenceDiagnostic?.code == code)
    }
  }

  // MARK: - Unsupported syntax is explicit

  @Test func assistantPromptIsAnExplicitDiagnostic() throws {
    let prompt = AssistantPrompt([.text("10 kg of water in ml")])
    let answered = try context().with(
      assistantAnswers: [prompt: .value(.number(.integer(IntegerValue(10_000))))])
    let table = table([
      ["=ask_assistant(10 kg of water in ml)", "=ask_assistant(10 kg of water in ml) * 2"]
    ])
    for context in [try context(), answered] {
      let snapshot = try calculate(table, context: context)
      for column in 0..<2 {
        let failure = failure(snapshot, address(table, 0, column))
        #expect(failure?.referenceDiagnostic?.code == .assistantPrompt)
        #expect(snapshot.traces[address(table, 0, column)]?.assistantPrompts.isEmpty ?? true)
      }
    }
  }

  @Test func unknownFunctionIsAnExplicitDiagnostic() throws {
    let table = table([["2", "=frobnicate(A2)", "=FROBNICATE(A2) + 1"]])
    let snapshot = try calculate(table)
    for column in 1...2 {
      let failure = failure(snapshot, address(table, 0, column))
      // Either the table's own diagnostic or the ordinary engine's error.
      #expect(
        failure?.referenceDiagnostic?.code.rawValue == "unknownFunction"
          || failure?.engineError?.code == .unknownFunction)
    }
  }

  @Test func spreadsheetOnlyFunctionsAndComparisonsAreUnsupported() throws {
    let formulas = [
      "=if(A2, 1, 2)", "=IF(A2 > 1, 1, 2)", "=iferror(A2, 0)", "=vlookup(A2, A:A, 1)",
      "=xlookup(A2, A:A, A:A)", "=index(A:A, 1)", "=match(A2, A:A)", "=concat(A2, A3)",
      "=left(A2, 1)", "=text(A2)", "=A2 > 1", "=A2 < 1", "=A2 = 1", "=A2 <> 1", "=and(A2, A3)",
      "=sumif(A:A, 1)",
    ]
    let table = table([["2"] + formulas, ["3"]])
    let snapshot = try calculate(table)
    for (offset, formula) in formulas.enumerated() {
      let result = snapshot.result(at: address(table, 0, offset + 1))
      guard case .failure(let failure) = result else {
        Issue.record("\(formula) must be an explicit diagnostic, got \(String(describing: result))")
        continue
      }
      let comparison = ["=A2 > 1", "=A2 < 1", "=A2 = 1", "=A2 <> 1"].contains(formula)
      #expect(
        failure.referenceDiagnostic?.code
          == (comparison ? .unsupportedComparison : .unsupportedFunction),
        "\(formula)")
    }
  }

  // MARK: - Bare keywords and inherited names

  @Test func bareAggregateAndPreviousKeepTheirDiagnostic() throws {
    let context = try context()
    let sheet = try prose("1\n2", context: context)
    let formulas = ["=sum", "=SUM", "=total", "=previous", "=Previous * 2", "=average + 1"]
    let table = table([["5"] + formulas])
    let snapshot = try calculate(table, prose: sheet)
    for column in 1...formulas.count {
      let failure = failure(snapshot, address(table, 0, column))
      #expect(failure?.referenceDiagnostic?.code == .bareAggregate)
    }
  }

  @Test func sheetQualifierResolvesAnInheritedVariableNamedCount() throws {
    let context = try context()
    let sheet = try prose("count = 4\ntotal = $3", context: context)
    let table = table([["2", "=sheet[count] * A2", "=sheet[total] * A2", "=count(A2, 7)"]])
    let snapshot = try calculate(table, prose: sheet)
    #expect(snapshot.result(at: address(table, 0, 1)) == (try ordinaryValue("8")))
    #expect(snapshot.result(at: address(table, 0, 2)) == (try ordinaryValue("$6")))
    // A call is still the built-in explicit-list count.
    #expect(snapshot.result(at: address(table, 0, 3)) == (try ordinaryValue("count(2, 7)")))
  }
}
