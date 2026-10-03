import Foundation
import Testing

@testable import GanitEngine

@Suite struct TableFormulaIndependentTests {
  @Test func referencesCountTowardSyntaxTokenBudget() throws {
    let limits = SyntaxLimits(maximumTokenCount: 3)
    let syntax = try TableFormulaSyntax.discover("=B2 + B2 + B2", limits: limits)
    let parsed = try syntax.parse(context: sheetContext(), limits: limits)
    #expect(parsed.expression == nil)
    #expect(parsed.diagnostics.contains { $0.code == .resourceLimitExceeded })
  }

  @Test func originalSourceByteBudgetSurvivesOperandMasking() throws {
    let limits = SyntaxLimits(maximumSourceUTF8Length: 5)
    let syntax = try TableFormulaSyntax.discover("=Items[Amount]", limits: limits)
    let parsed = try syntax.parse(context: sheetContext(), limits: limits)
    #expect(parsed.expression == nil)
    #expect(parsed.diagnostics.contains { $0.code == .resourceLimitExceeded })
  }

  @Test func decomposedHeadersKeepExactOperandAndFollowingTokenRanges() throws {
    let table = TableModel.creating(
      name: "Expenses", headers: [("Cafe\u{301} 👩🏽‍💻", .value)], rowCount: 1)
    let source = "=Expenses[Cafe\u{301} 👩🏽‍💻] × 2 + Expenses!A2"
    let syntax = try TableFormulaSyntax.discover(source)
    let bound = try syntax.bind(
      scope: TableFormulaScope(current: table, visible: [], inherited: [:]))
    #expect(bound.count == 2)
    #expect(bound[0].target == .namedColumn(table: table.id, column: table.columns[0].id))
    #expect(
      bound[1].target == .cell(table: table.id, row: table.rows[0], column: table.columns[0].id))
    #expect(syntax.references[0].range.text(in: source) == "Expenses[Cafe\u{301} 👩🏽‍💻]")
    let multiply = try #require(syntax.tokens.first { $0.kind == .multiply })
    #expect(multiply.range.text(in: source) == "×")
    #expect(multiply.range.graphemeLowerBound == source.prefix { $0 != "×" }.count)
    #expect(try syntax.parse(context: sheetContext()).expression != nil)
  }

  @Test func escapedInheritedNamesDoNotConsumePersistedReferenceOrdinals() throws {
    let table = TableModel.creating(name: "Items", headers: [("Value", .value)], rowCount: 1)
    let source = "=sheet[cost\\] label] + A2"
    let syntax = try TableFormulaSyntax.discover(source)
    let span = try #require(syntax.references.last).range
    let binding = TableBinding(
      operand: span.lowerBound..<span.upperBound,
      target: .cell(table: table.id, row: table.rows[0], column: table.columns[0].id),
      locks: [false, false])
    let ledger = TableLedgerEntry(
      owner: .cell(row: table.rows[0], column: table.columns[0].id),
      fingerprint: source, bindings: [binding])
    let bound = try syntax.bind(
      scope: TableFormulaScope(
        current: table, visible: [], inherited: ["cost] label": .number(.integer(IntegerValue(4)))]),
      ledger: ledger)
    #expect(bound[0].inheritedName == "cost] label")
    #expect(bound[1].target == binding.target)
  }

  @Test func ordinaryQualifiedReferencesRespectVisibilityAndPreserveBareAddressVariables() throws {
    let earlier = TableModel.creating(name: "Items", headers: [("Value", .value)], rowCount: 1)
    let source = "A2 + Items!A2 + sum(Items[Value])"
    let syntax = try TableFormulaSyntax.discover(source, tableFormula: false)
    #expect(syntax.references.count == 2)
    #expect(throws: TableFormulaDiagnostic.self) {
      try syntax.bind(scope: TableFormulaScope(current: nil, visible: [], inherited: [:]))
    }
    let bound = try syntax.bind(
      scope: TableFormulaScope(current: nil, visible: [earlier], inherited: [:]))
    #expect(bound.allSatisfy { $0.target?.table == earlier.id })
    let parsed = try syntax.parse(context: sheetContext(), inheritedKinds: ["a2": .number])
    #expect(parsed.expression?.identifiers.contains("a2") == true)
  }
}
