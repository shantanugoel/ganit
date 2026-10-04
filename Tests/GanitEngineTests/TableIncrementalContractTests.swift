import Foundation
import Testing

@testable import GanitEngine

/// Independent task-5 contracts: observable values, invalidation and bounded
/// generation work. Expectations follow ADR 0016/0017 and M0 resource evidence.
@Suite struct TableIncrementalContractTests {
  private let calculator = TableCalculator()
  private func table(_ inputs: [[String]], name: String = "Items") -> TableModel {
    let columns = inputs.map(\.count).max() ?? 1
    var result = TableModel.creating(
      name: name, headers: (0..<columns).map { ("Field\($0)", .value) }, rowCount: inputs.count)
    for (row, values) in inputs.enumerated() {
      for (column, source) in values.enumerated() where !source.isEmpty {
        result.cells.append(
          TableCell(row: result.rows[row], column: result.columns[column].id, source: source))
      }
    }
    return result
  }

  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }

  private func calculate(
    _ table: TableModel, previous: TableCalculationSnapshot? = nil,
    visible: [TableModel] = [], inherited: [String: EngineValue?] = [:],
    earlier: [TableID: TableCalculationSnapshot] = [:],
    context: EvaluationContext? = nil, scopeOverride: TableFormulaScope? = nil,
    options: TableCalculationOptions? = nil,
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> TableCalculationSnapshot {
    try (options.map { TableCalculator(options: $0) } ?? calculator).calculate(
      table,
      scope: scopeOverride
        ?? TableFormulaScope(current: table, visible: visible, inherited: inherited),
      context: context ?? sheetContext(), earlier: earlier, previous: previous, cancelled: cancelled
    )
  }

  private func expectLimit(_ body: () throws -> TableCalculationSnapshot) {
    do {
      _ = try body()
      Issue.record("Generation exceeded a configured limit without a diagnostic")
    } catch let error as EngineError {
      #expect(error.code == .resourceLimitExceeded)
    } catch {
      Issue.record("Unexpected limit failure: \(error)")
    }
  }

  @Test func valueEditRecalculatesReadersWithoutReparsingUnrelatedCells() throws {
    var model = table([["2", "=A2 * 3", "=B2 + 1", "=40 + 2", "=1 +"]])
    let first = try calculate(model)
    model.cells[0].source = "5"
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 2)) == number(16))
    #expect(next.result(at: address(model, 0, 3)) == number(42))
    #expect(next.result(at: address(model, 0, 4)) == first.result(at: address(model, 0, 4)))
    #expect(next.parsedFormulas == 0)
    #expect(next.reusedCells >= 2)
    #expect(first.result(at: address(model, 0, 2)) == number(7))
    #expect(next.outcomes == (try calculate(model)).outcomes)
  }

  @Test func unchangedGenerationDoesNoScalarOrFormulaWork() throws {
    let model = table([["2", "=A2 + 3", "=sum(A:A)"]])
    let first = try calculate(model)
    let next = try calculate(model, previous: first)
    #expect(next.outcomes == first.outcomes)
    #expect(next.parsedFormulas == 0)
    #expect(next.evaluatedCells == 0)
    #expect(next.scalarOperations == 0)
    #expect(next.rangeCellVisits == 0)
  }

  @Test func formulaEditReplacesEdgesAndInvalidatesTransitiveReaders() throws {
    var model = table([["2", "10", "=A2 + 1", "=C2 * 2", "=100 + 1"]])
    let first = try calculate(model)
    model.cells[2].source = "=B2 + 1"
    let rewired = try calculate(model, previous: first)
    #expect(rewired.result(at: address(model, 0, 3)) == number(22))
    #expect(rewired.parsedFormulas == 1)
    model.cells[0].source = "99"
    let unrelated = try calculate(model, previous: rewired)
    #expect(unrelated.result(at: address(model, 0, 3)) == number(22))
    #expect(unrelated.evaluatedCells == 1)
    #expect(unrelated.parsedFormulas == 0)
  }

  @Test func sourceEditCanCreateAndRepairACycle() throws {
    var model = table([["1", "=A2 + 1", "=B2 + 1", "=9"]])
    let first = try calculate(model)
    model.cells[0].source = "=B2"
    let cycle = try calculate(model, previous: first)
    guard case .failure(let cyclic) = cycle.result(at: address(model, 0, 0)),
      case .failure(let blocked) = cycle.result(at: address(model, 0, 2))
    else {
      Issue.record("Expected cycle and blocked reader")
      return
    }
    #expect(cyclic.code == .cycle)
    #expect(blocked.code == .blocked)
    model.cells[0].source = "7"
    let repaired = try calculate(model, previous: cycle)
    #expect(repaired.result(at: address(model, 0, 2)) == number(9))
    #expect(repaired.outcomes == (try calculate(model)).outcomes)
  }

  @Test func inheritedValueEditInvalidatesDependentValues() throws {
    let model = table([["=sheet[rate] * 2", "=A2 + 1", "=5"]])
    let first = try calculate(model, inherited: ["rate": .number(.integer(IntegerValue(3)))])
    let next = try calculate(
      model, previous: first, inherited: ["rate": .number(.integer(IntegerValue(10)))])
    #expect(next.result(at: address(model, 0, 1)) == number(21))
    #expect(first.result(at: address(model, 0, 1)) == number(7))
  }

  @Test func contextAndClockChangesCannotReuseStaleValues() throws {
    let model = table([["=today", "=sin(90)", "=A2 + 1 day"]])
    let first = try calculate(model)
    let changedContext = try sheetContext(angleMode: .degrees).at(
      Date(timeIntervalSince1970: 86_400))
    let next = try calculate(model, previous: first, context: changedContext)
    #expect(next.result(at: address(model, 0, 0)) != first.result(at: address(model, 0, 0)))
    #expect(next.result(at: address(model, 0, 1)) != first.result(at: address(model, 0, 1)))
    #expect(next.outcomes == (try calculate(model, context: changedContext)).outcomes)
  }

  @Test func earlierSnapshotEditInvalidatesCrossTableReaders() throws {
    var rates = table([["3"]], name: "Rates")
    let model = table([["=Rates!A2 * 2", "=A2 + 1", "=8"]])
    let oldRates = try calculate(rates)
    let first = try calculate(model, visible: [rates], earlier: [rates.id: oldRates])
    rates.cells[0].source = "10"
    let newRates = try calculate(rates, previous: oldRates)
    let next = try calculate(
      model, previous: first, visible: [rates], earlier: [rates.id: newRates])
    #expect(next.result(at: address(model, 0, 1)) == number(21))
    #expect(first.result(at: address(model, 0, 1)) == number(7))
    let missing = try calculate(model, previous: next, visible: [rates])
    guard case .failure(let failure) = missing.result(at: address(model, 0, 0)) else {
      Issue.record("Removed earlier snapshot reused a scalar")
      return
    }
    #expect(failure.code == .reference)
  }

  @Test func wholeColumnMembershipIncludesNewRows() throws {
    var model = table([["1", "=sum(A:A)"], ["2", ""]])
    let first = try calculate(model)
    let row = RowID.mint()
    model.rows.append(row)
    model.cells.append(TableCell(row: row, column: model.columns[0].id, source: "4"))
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 1)) == number(7))
    #expect(next.outcomes == (try calculate(model)).outcomes)
  }

  @Test func rangeMemberEditInvalidatesSharedReductionAndItsReaders() throws {
    var model = table([["1", "=sum(A:A)", "=B2 + 1"], ["2", "=sum(A:A)", "=B3 * 2"]])
    let first = try calculate(model)
    model.cells.firstIndex { $0.row == model.rows[1] && $0.column == model.columns[0].id }.map {
      model.cells[$0].source = "4"
    }
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 2)) == number(6))
    #expect(next.result(at: address(model, 1, 2)) == number(10))
    #expect(next.parsedFormulas == 0)
    #expect(next.rangeCellVisits == 2)
  }

  @Test func rangeValueKindChangeIsReparsedByOrdinaryEngine() throws {
    var model = table([["$2", "=sum(A:A)", "=B2 * 2"], ["$3", "", ""]])
    let first = try calculate(model)
    model.cells[0].source = "2 m"
    let next = try calculate(model, previous: first)
    #expect(next.outcomes == (try calculate(model)).outcomes)
    guard case .failure = next.result(at: address(model, 0, 1)) else {
      Issue.record("Incompatible updated range reused money result")
      return
    }
  }

  @Test func defaultUnitAndRuleEditInvalidateDependentCells() throws {
    var model = table([["2", "", "=B2 * 2"], ["3", "", ""]])
    model.columns[0].unit = "m"
    model.columns[1].rule = "=A2 * 3"
    let first = try calculate(model)
    model.columns[0].unit = "cm"
    model.columns[1].rule = "=A2 * 4"
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 2)) != first.result(at: address(model, 0, 2)))
    #expect(next.outcomes == (try calculate(model)).outcomes)
  }

  @Test func productionPopulationCeilingIsPerSheetAcrossVisibleTables() throws {
    let earlier = table((0..<2_000).map { _ in ["1"] }, name: "Earlier")
    let current = table((0..<2_000).map { _ in ["2"] })
    #expect(TableCalculationOptions.production.maximumPopulatedCells == 4_000)
    _ = try calculate(current, visible: [earlier])
    var over = current
    let row = RowID.mint()
    over.rows.append(row)
    over.cells.append(TableCell(row: row, column: over.columns[0].id, source: "3"))
    expectLimit { try calculate(over, visible: [earlier]) }
    // A repeated scope model represents the same table, not extra population.
    _ = try calculate(current, visible: [earlier, earlier])
  }

  @Test func rulePopulationCountsTowardsAdmission() throws {
    var model = table((0..<2_001).map { _ in ["1", ""] })
    model.columns[1].rule = "=A2 * 2"
    expectLimit { try calculate(model) }
  }

  @Test func sharedRangeLinksAreCountedOnceAndExactLimitIsAllowed() throws {
    let model = table([["1", "=sum(A:A)", "=sum(A:A)"], ["2", "", ""]])
    let options = TableCalculationOptions(maximumPopulatedCells: 4_000, maximumDependencyLinks: 4)
    let snapshot = try calculate(model, options: options)
    #expect(snapshot.dependencyLinks == 4)
    #expect(snapshot.result(at: address(model, 0, 2)) == number(3))
    expectLimit {
      try calculate(
        model,
        options: TableCalculationOptions(maximumPopulatedCells: 4_000, maximumDependencyLinks: 3))
    }
  }

  @Test func runningRangesCannotEvadeProductionDependencyLimit() {
    let model = table((0..<450).map { row in ["1", "=sum(A2:A\(row + 2))"] })
    #expect(model.populatedCellCount < 4_000)
    expectLimit { try calculate(model) }
  }

  @Test func rangeVisitLimitIsPerGenerationAndSharedReadersReuseVisits() throws {
    let model = table([["1", "=sum(A:A)", "=sum(A:A)"], ["2", "", ""]])
    let allowed = TableCalculationOptions(maximumPopulatedCells: 4_000, maximumRangeCellVisits: 2)
    let snapshot = try calculate(model, options: allowed)
    #expect(snapshot.rangeCellVisits == 2)
    expectLimit {
      try calculate(
        model,
        options: TableCalculationOptions(maximumPopulatedCells: 4_000, maximumRangeCellVisits: 1))
    }
  }

  @Test func productionRangeVisitBudgetIsOneMillion() {
    let model = table((0..<1_415).map { row in ["1", "=sum(A2:A\(row + 2))"] })
    // Give the link and scalar budgets ample headroom so only the production
    // million-visit limit can reject this 1,001,820-member generation.
    do {
      _ = try calculate(
        model,
        options: TableCalculationOptions(
          maximumPopulatedCells: 4_000, maximumDependencyLinks: 2_000_000,
          maximumScalarOperations: 100_000_000))
      Issue.record("Million range-cell visits completed without a diagnostic")
    } catch let error as EngineError {
      #expect(error.code == .resourceLimitExceeded)
      #expect(error.context != .resourceLimit(.operations))
      #expect(error.context == .none)
    } catch {
      Issue.record("Unexpected range-visit limit failure: \(error)")
    }
  }

  @Test func scalarBudgetIsSharedAcrossIndividuallyLegalCells() throws {
    let single = table([["=1 + 2 + 3 + 4"]])
    let cost = try calculate(single).scalarOperations
    #expect(cost > 0)
    let many = table((0..<20).map { _ in ["=1 + 2 + 3 + 4"] })
    let allowed = TableCalculationOptions(
      maximumPopulatedCells: 4_000, maximumScalarOperations: cost)
    #expect(
      (try calculate(single, options: allowed)).result(at: address(single, 0, 0)) == number(10))
    expectLimit { try calculate(many, options: allowed) }
  }

  @Test func changedOptionsCannotBypassLimitsWithPriorSnapshot() throws {
    let model = table([["1", "=A2 + 1", "=B2 + 1"]])
    let previous = try calculate(model)
    expectLimit {
      try calculate(
        model, previous: previous,
        options: TableCalculationOptions(maximumPopulatedCells: 4_000, maximumDependencyLinks: 1))
    }
    #expect(previous.result(at: address(model, 0, 2)) == number(3))
  }

  @Test func cancellationThrowsAndPreservesPreviousSnapshot() throws {
    var model = table([["1", "=A2 + 1"]])
    let previous = try calculate(model)
    model.cells[0].source = "9"
    do {
      _ = try calculate(model, previous: previous, cancelled: { true })
      Issue.record("Cancelled calculation returned a snapshot")
    } catch is CancellationError {
      #expect(previous.result(at: address(model, 0, 1)) == number(2))
    }
    let next = try calculate(model, previous: previous)
    #expect(next.result(at: address(model, 0, 1)) == number(10))
  }

  @Test func inheritedFunctionsAndProvenanceCannotReuseStaleClosure() throws {
    let model = table([["=double(3)", "=A2 + 1"]])
    var calculator = SheetCalculator()
    let old = try calculator.evaluate(SheetSource("double(x) = x * 2"), context: sheetContext())
    let new = try calculator.evaluate(SheetSource("double(x) = x * 4"), context: sheetContext())
    var scope = TableFormulaScope(current: model, visible: [], inherited: [:])
    scope.functions = old.definitions.functions
    let first = try calculate(model, scopeOverride: scope)
    scope.functions = new.definitions.functions
    scope.functionProvenance["double"] = TableCellProvenance(clock: .day)
    let next = try calculate(model, previous: first, scopeOverride: scope)
    #expect(next.result(at: address(model, 0, 1)) == number(13))
    #expect(next.provenance[address(model, 0, 1)]?.clock == .day)
    #expect(first.result(at: address(model, 0, 1)) == number(7))
  }

  @Test func physicalLineChangesAndTableLineQuarantineInvalidateReads() throws {
    let model = table([["=@1 * 2", "=A2 + 1"]])
    var scope = TableFormulaScope(current: model, visible: [], inherited: [:])
    scope.lines.append(.value(.number(.integer(IntegerValue(3)))))
    let first = try calculate(model, scopeOverride: scope)
    scope.lines = LineOutcomes()
    scope.lines.append(.value(.number(.integer(IntegerValue(10)))))
    let next = try calculate(model, previous: first, scopeOverride: scope)
    #expect(next.result(at: address(model, 0, 1)) == number(21))
    scope.tableLines.insert(0)
    let quarantined = try calculate(model, previous: next, scopeOverride: scope)
    guard case .failure(let failure) = quarantined.result(at: address(model, 0, 0)) else {
      Issue.record("Table line quarantine reused a scalar")
      return
    }
    #expect(failure.referenceDiagnostic?.code == .tableLineReference)
  }

  @Test func headerRepairRebindsNamedColumn() throws {
    var model = table([["2", "=sum(Items[Amount])", ""]])
    let first = try calculate(model)
    model.columns[0].header = "Amount"
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 1)) == number(2))
    #expect(next.outcomes == (try calculate(model)).outcomes)
  }

  @Test func sparseRectangleLimitRejectsBeforeExpandingAllMembers() {
    var model = TableModel.creating(
      name: "Items", headers: (0..<1_000).map { ("Field\($0)", .value) }, rowCount: 1_000)
    model.cells.append(
      TableCell(row: model.rows[0], column: model.columns[999].id, source: "=sum(A2:ALL1001)"))
    expectLimit { try calculate(model) }
  }

  @Test func kindChangePreservesStaticErrorPrecedenceOverBlockedInput() throws {
    var model = table([["20%", "=1 / 0", "=A2 of B2%"]])
    let first = try calculate(model)
    model.cells[0].source = "5 m"
    let next = try calculate(model, previous: first)
    let full = try calculate(model)
    #expect(next.outcomes == full.outcomes)
    model.cells[0].source = "20%"
    let restored = try calculate(model, previous: next)
    #expect(restored.outcomes == first.outcomes)
  }

  @Test func deletedBindingDoesNotRepairWhenCoordinateIsReused() throws {
    var model = table([["", "=A2 + 1"]])
    let gone = RowID.mint()
    var binding = TableBinding(
      operand: 1..<2, target: .cell(table: model.id, row: gone, column: model.columns[0].id),
      locks: [false, false], isDeleted: true)
    let source = "=" + binding.brokenMarker
    binding.operand = 1..<source.utf8.count
    model.cells.append(TableCell(row: model.rows[0], column: model.columns[0].id, source: source))
    model.ledger = [
      TableLedgerEntry(
        owner: .cell(row: model.rows[0], column: model.columns[0].id), fingerprint: source,
        bindings: [binding])
    ]
    let first = try calculate(model)
    let replacement = RowID.mint()
    model.rows.append(replacement)
    model.cells.append(TableCell(row: replacement, column: model.columns[0].id, source: "99"))
    let next = try calculate(model, previous: first)
    guard case .failure(let failure) = next.result(at: address(model, 0, 0)) else {
      Issue.record("Deleted marker repaired itself")
      return
    }
    #expect(failure.referenceDiagnostic?.code == .brokenReference)
    #expect(next.result(at: address(model, 0, 1)) == first.result(at: address(model, 0, 1)))
  }

  @Test func customFunctionBodySharesTheGenerationOperationBudget() throws {
    var prose = SheetCalculator()
    let definitions = try prose.evaluate(
      SheetSource("heavy(x) = x * 2 + x * 3 + x * 4 + x * 5"), context: sheetContext()
    ).definitions
    let single = table([["=heavy(2)"]])
    var scope = TableFormulaScope(current: single, visible: [], inherited: [:])
    scope.functions = definitions.functions
    let cost = try calculate(single, scopeOverride: scope).scalarOperations
    #expect(cost > 0)
    let many = table((0..<20).map { _ in ["=heavy(2)"] })
    scope.current = many
    let options = TableCalculationOptions(
      maximumPopulatedCells: 4_000, maximumScalarOperations: cost)
    expectLimit { try calculate(many, scopeOverride: scope, options: options) }
  }

  @Test func emptyTypedRangeDefaultChangeInvalidatesItsZero() throws {
    var model = table([["", "=sum(A:A)"]])
    model.columns[0].unit = "m"
    let first = try calculate(model)
    model.columns[0].unit = "cm"
    let next = try calculate(model, previous: first)
    #expect(next.result(at: address(model, 0, 1)) != first.result(at: address(model, 0, 1)))
    #expect(next.outcomes == (try calculate(model)).outcomes)
  }

  @Test func emptyEarlierRangeDefaultChangeInvalidatesItsZero() throws {
    var rates = TableModel.creating(name: "Rates", headers: [("Length", .value)], rowCount: 0)
    rates.columns[0].unit = "m"
    let model = table([["=sum(Rates!A:A)"]])
    let oldRates = try calculate(rates)
    let first = try calculate(model, visible: [rates], earlier: [rates.id: oldRates])
    rates.columns[0].unit = "cm"
    let newRates = try calculate(rates, previous: oldRates)
    let next = try calculate(
      model, previous: first, visible: [rates], earlier: [rates.id: newRates])
    #expect(next.result(at: address(model, 0, 0)) != first.result(at: address(model, 0, 0)))
    #expect(
      next.outcomes
        == (try calculate(model, visible: [rates], earlier: [rates.id: newRates])).outcomes)
  }

  @Test func freedStaticCheckBudgetRechecksPreviouslyBlockedOwnSyntax() throws {
    var model = table([["=1 / 0", "=A2 +", "=A2 *"]])
    let calculator = TableCalculator(
      options: TableCalculationOptions(
        maximumPopulatedCells: 4_000, maximumStaticCheckParses: 9))
    func run(_ model: TableModel, previous: TableCalculationSnapshot? = nil) throws
      -> TableCalculationSnapshot
    {
      try calculator.calculate(
        model,
        scope: TableFormulaScope(current: model, visible: [], inherited: [:]),
        context: sheetContext(), previous: previous)
    }
    let first = try run(model)
    guard case .failure(let oldB) = first.result(at: address(model, 0, 1)),
      case .failure(let oldC) = first.result(at: address(model, 0, 2))
    else {
      Issue.record("Expected own syntax and exhausted static budget")
      return
    }
    #expect(oldB.code == .syntax)
    #expect(oldC.code == .blocked)
    model.cells[1].source = "=1"
    let next = try run(model, previous: first)
    let cold = try run(model)
    guard case .failure(let newC) = cold.result(at: address(model, 0, 2)) else {
      Issue.record("Expected freed static budget to diagnose own syntax")
      return
    }
    #expect(newC.code == .syntax)
    #expect(next.outcomes == cold.outcomes)
  }

  @Test func manualRateScopeEditInvalidatesConversions() throws {
    let model = table([["$10", "=A2 in INR", "=B2 * 2"]])
    var scope = TableFormulaScope(current: model, visible: [], inherited: [:])
    let pair = CurrencyPair(from: "USD", to: "INR")
    scope.rates[pair] = .integer(IntegerValue(80))
    let first = try calculate(model, scopeOverride: scope)
    scope.rates[pair] = .integer(IntegerValue(90))
    let next = try calculate(model, previous: first, scopeOverride: scope)
    #expect(next.result(at: address(model, 0, 2)) != first.result(at: address(model, 0, 2)))
    #expect(next.outcomes == (try calculate(model, scopeOverride: scope)).outcomes)
  }

  @Test func inheritedUnitDefinitionEditInvalidatesLiteralsAndConversions() throws {
    let model = table([["2 bag", "=A2 in kg"]])
    var prose = SheetCalculator()
    let old = try prose.evaluate(SheetSource("1 bag = 25 kg"), context: sheetContext())
    let new = try prose.evaluate(SheetSource("1 bag = 50 kg"), context: sheetContext())
    var scope = TableFormulaScope(current: model, visible: [], inherited: [:])
    scope.units = .resolving(old.definitions.units)
    let first = try calculate(model, scopeOverride: scope)
    scope.units = .resolving(new.definitions.units)
    let next = try calculate(model, previous: first, scopeOverride: scope)
    #expect(next.result(at: address(model, 0, 1)) != first.result(at: address(model, 0, 1)))
    #expect(next.outcomes == (try calculate(model, scopeOverride: scope)).outcomes)
  }

  @Test func concurrentGenerationsShareOnlyImmutableSnapshotState() async throws {
    let model = table([["1", "=A2 + 1", "=B2 * 2", "=sum(A:A)"]])
    let previous = try calculate(model)
    let context = try sheetContext()
    let calculator = self.calculator
    try await withThrowingTaskGroup(of: (Int, TableCalculationSnapshot).self) { group in
      for value in 2...9 {
        group.addTask {
          var edited = model
          edited.cells[0].source = String(value)
          let snapshot = try calculator.calculate(
            edited,
            scope: TableFormulaScope(current: edited, visible: [], inherited: [:]),
            context: context, previous: previous)
          return (value, snapshot)
        }
      }
      for try await (value, snapshot) in group {
        #expect(snapshot.result(at: address(model, 0, 2)) == number((value + 1) * 2))
        #expect(snapshot.result(at: address(model, 0, 3)) == number(value))
        #expect(snapshot.parsedFormulas == 0)
      }
    }
    #expect(previous.result(at: address(model, 0, 2)) == number(4))
    #expect(previous.result(at: address(model, 0, 3)) == number(1))
  }

}
