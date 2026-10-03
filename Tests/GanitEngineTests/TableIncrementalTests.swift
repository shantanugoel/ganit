import Foundation
import Testing

@testable import GanitEngine

@Suite struct TableIncrementalTests {
  private func table(_ sources: [String]) -> TableModel {
    var model = TableModel.creating(
      name: "Items", headers: [("Value", .value)], rowCount: sources.count)
    model.cells = zip(model.rows, sources).map {
      TableCell(row: $0.0, column: model.columns[0].id, source: $0.1)
    }
    return model
  }

  @Test func factorialIterationsShareGenerationBudget() throws {
    let model = table(["=fact(100)", "=fact(100)"])
    let context = try sheetContext()
    let one = table(["=fact(100)"])
    let cost = try TableCalculator().calculate(
      one, scope: .init(current: one, visible: [], inherited: [:]), context: context
    ).scalarOperations
    let calculator = TableCalculator(
      options: .init(maximumPopulatedCells: 4_000, maximumScalarOperations: cost + 2))
    #expect(throws: EngineError.self) {
      try calculator.calculate(
        model, scope: .init(current: model, visible: [], inherited: [:]), context: context)
    }
  }

  @Test func repeatedCustomCallsSharePerCellASTLimit() throws {
    let context = try sheetContext()
    let engine = CalculationEngine(evaluationLimits: .init(maximumOperations: 5))
    let body = try #require(
      engine.parse("x + 1", context: context, variables: ["x": .number]).expression)
    let function = CustomFunction(
      name: "f", parameters: ["x"], body: body, variables: [:], functions: [:])
    let expression = try #require(engine.parse("f(1) + f(1)", context: context).expression)
    let ordinary = engine.evaluate(
      expression, context: context, variables: [:], lines: LineOutcomes(),
      functions: ["f": function])
    guard case .evaluationFailure(let error) = ordinary.result else {
      Issue.record("Repeated custom calls must use the caller's operation ceiling")
      return
    }
    #expect(error.code == .resourceLimitExceeded)
    let model = table(["=f(1) + f(1)"])
    let result = try TableCalculator(engine: engine).calculate(
      model, scope: .init(current: model, visible: [], inherited: [:], functions: ["f": function]),
      context: context)
    guard
      case .failure(let failure) = result.outcomes[
        TableCellAddress(table: model.id, row: model.rows[0], column: model.columns[0].id)]
    else {
      Issue.record("Table custom calls must retain the per-cell ceiling")
      return
    }
    #expect(failure.engineError?.code == .resourceLimitExceeded)
  }

  @Test func snapshotDoesNotRetainRemovedSources() throws {
    var model = table(["=2 + 3", "=A2 * 2"])
    let context = try sheetContext()
    let calculator = TableCalculator()
    let first = try calculator.calculate(
      model, scope: .init(current: model, visible: [], inherited: [:]), context: context)
    model.cells.removeLast()
    let second = try calculator.calculate(
      model, scope: .init(current: model, visible: [], inherited: [:]), context: context,
      previous: first)
    #expect(second.sources.count == 2)
    #expect(second.nodes.count == 2)
    #expect(second.reusedCells == 1)
    #expect(second.parsedFormulas == 0)
  }

  @Test func successfulValueEditKeepsUnrelatedLiteralAndFormula() throws {
    var model = table(["0.1", "=A2 + 0.2", "=10 USD / 4"])
    let context = try sheetContext()
    let calculator = TableCalculator()
    let first = try calculator.calculate(
      model, scope: .init(current: model, visible: [], inherited: [:]), context: context)
    model.cells[0].source = "0.2"
    let next = try calculator.calculate(
      model, scope: .init(current: model, visible: [], inherited: [:]), context: context,
      previous: first)
    let cold = try calculator.calculate(
      model, scope: .init(current: model, visible: [], inherited: [:]), context: context)
    #expect(next.outcomes == cold.outcomes)
    #expect(next.parsedFormulas == 0)
    #expect(next.evaluatedCells == 2)
    #expect(next.reusedCells == 1)
  }
}
