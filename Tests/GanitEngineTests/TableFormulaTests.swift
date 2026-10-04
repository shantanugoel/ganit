import Foundation
import Testing

@testable import GanitEngine

@Suite struct TableFormulaTests {
  private func table(_ name: String = "Items", rows: Int = 4) -> TableModel {
    .creating(
      name: name, headers: [("Qty", .value), ("Unit price", .value), ("Amount", .value)],
      rowCount: rows)
  }

  @Test(arguments: ["B2", "$B$2", "$B2", "B$2", "b2"])
  func scalarAddress(_ operand: String) throws {
    let t = table()
    let syntax = try TableFormulaSyntax.discover("=\(operand) * 2")
    let bound = try syntax.bind(scope: TableFormulaScope(current: t, visible: [], inherited: [:]))
    #expect(bound.count == 1)
    #expect(bound[0].target == .cell(table: t.id, row: t.rows[0], column: t.columns[1].id))
    #expect(bound[0].occurrence.range.text(in: syntax.source) == Substring(operand))
    #expect(bound[0].locks == [operand.contains("$2"), operand.hasPrefix("$")])
    #expect(try syntax.parse(context: sheetContext()).expression != nil)
  }

  @Test(arguments: [
    "B2:C4", "$B$2:$C4", "C:C", "$B:$C", "2:2", "$2:$4", "Items!2:4", "Items!2:Items!4",
    "Items!B:Items!C", "Items!B2:Items!C4", "Items[Amount]", "[@Qty]", "[@[Unit price]]",
  ])
  func rangeAndStructuredForms(_ operand: String) throws {
    let t = table()
    let syntax = try TableFormulaSyntax.discover("=sum(\(operand))")
    let bound = try syntax.bind(scope: TableFormulaScope(current: t, visible: [], inherited: [:]))
    #expect(bound.count == 1)
    #expect(bound[0].target?.hasBindingID == true)
    #expect(try syntax.parse(context: sheetContext()).expression != nil)
  }

  @Test func inheritedScopeAndOrdinaryMode() throws {
    let t = table()
    let value = EngineValue.number(.integer(IntegerValue(7)))
    let syntax = try TableFormulaSyntax.discover("=sheet[B2] + B2")
    let bound = try syntax.bind(
      scope: TableFormulaScope(current: t, visible: [], inherited: ["b2": value]))
    #expect(bound[0].inheritedName == "b2")
    #expect(bound[1].target == .cell(table: t.id, row: t.rows[0], column: t.columns[1].id))
    let ordinary = try TableFormulaSyntax.discover(
      "B2 + sum(Items[Amount]) + Items!B2", tableFormula: false)
    #expect(ordinary.references.count == 2)
    let ordinaryBindings = try ordinary.bind(
      scope: TableFormulaScope(current: nil, visible: [t], inherited: ["b2": value]))
    #expect(ordinaryBindings.allSatisfy { $0.target?.table == t.id })
    let parsing = try ordinary.parse(context: sheetContext(), inheritedKinds: ["b2": .number])
    #expect(parsing.expression?.identifiers.contains("b2") == true)
  }

  @Test func scalarOperandsUseExistingExactEvaluator() throws {
    let context = try sheetContext()
    let syntax = try TableFormulaSyntax.discover("=B2 + C2")
    let parsing = try syntax.parse(context: context)
    let expression = try #require(parsing.expression)
    let a = try Evaluator(context: context).evaluate(
      #require(Parser(source: "0.1").parse().expression))
    let b = try Evaluator(context: context).evaluate(
      #require(Parser(source: "0.2").parse().expression))
    let result = CalculationEngine().evaluate(
      expression, context: context,
      variables: [syntax.references[0].slot: a, syntax.references[1].slot: b], lines: LineOutcomes()
    ).result
    let expected = try Evaluator(context: context).evaluate(
      #require(Parser(source: "0.3").parse().expression))
    #expect(result == .value(expected))
  }

  @Test func coordinateAndLedgerAgreement() throws {
    let t = table()
    let syntax = try TableFormulaSyntax.discover("=$B$2")
    let owner = TableFormulaOwner.cell(row: t.rows[0], column: t.columns[0].id)
    let scope = TableFormulaScope(current: t, visible: [], inherited: [:])
    let binding = TableBinding(
      operand: 1..<5,
      target: .cell(table: t.id, row: t.rows[0], column: t.columns[1].id), locks: [true, true])
    let ledger = TableLedgerEntry(owner: owner, fingerprint: syntax.source, bindings: [binding])
    #expect(try syntax.bind(scope: scope, ledger: ledger).count == 1)
    var wrong = ledger
    wrong.bindings[0].target = .cell(table: t.id, row: t.rows[1], column: t.columns[1].id)
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope, ledger: wrong) }
    wrong = ledger
    wrong.bindings[0].locks = [false, false]
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope, ledger: wrong) }
    wrong = ledger
    wrong.bindings[0].operand = 1..<4
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope, ledger: wrong) }
    wrong = ledger
    wrong.fingerprint = "=B3"
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope, ledger: wrong) }
    wrong = ledger
    wrong.bindings = []
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope, ledger: wrong) }
  }

  @Test func visibilityAndBoundedAddresses() throws {
    let t = table()
    let earlier = table("Rates")
    let scope = TableFormulaScope(current: t, visible: [earlier], inherited: [:])
    #expect(
      try TableFormulaSyntax.discover("=rAtEs!B2").bind(scope: scope).first?.target?.table
        == earlier.id)
    for source in ["=Later!B2", "=A0", "=A6", "=D2", "=B4:A2", "=A1:B2", "=Items[Unknown]"] {
      #expect(throws: TableFormulaDiagnostic.self) {
        try TableFormulaSyntax.discover(source).bind(scope: scope)
      }
    }
    #expect(
      try TableFormulaSyntax.discover("=B1").bind(scope: scope).first?.target
        == .cell(table: t.id, row: nil, column: t.columns[1].id))
    #expect(throws: TableFormulaDiagnostic.self) {
      try TableFormulaSyntax.discover("=Rates!B2:Items!C3")
    }
    #expect(throws: TableFormulaDiagnostic.self) {
      try TableFormulaSyntax.discover("=Rates!2:Items!3")
    }
  }

  @Test func brokenMarkersNeverRebind() throws {
    let t = table()
    let gone = RowID.mint()
    var binding = TableBinding(
      operand: 1..<2, target: .cell(table: t.id, row: gone, column: t.columns[0].id),
      locks: [false, false], isDeleted: true)
    let source = "=" + binding.brokenMarker
    binding.operand = 1..<source.utf8.count
    let ledger = TableLedgerEntry(
      owner: .cell(row: t.rows[0], column: t.columns[0].id), fingerprint: source,
      bindings: [binding])
    let syntax = try TableFormulaSyntax.discover(source)
    let scope = TableFormulaScope(current: t, visible: [], inherited: [:])
    #expect(try syntax.bind(scope: scope, ledger: ledger).first?.deleted == true)
    #expect(throws: TableFormulaDiagnostic.self) { try syntax.bind(scope: scope) }
  }

  @Test func escapedNamesAndUnicodeSourceRanges() throws {
    let t = TableModel.creating(
      name: "देवनागरी ` budget", headers: [("Unit ] price\\₹|USD", .value)], rowCount: 1)
    let source = "= `देवनागरी `` budget`[Unit \\] price\\\\₹|USD] + 1"
    let syntax = try TableFormulaSyntax.discover(source)
    #expect(syntax.references.count == 1)
    #expect(
      try syntax.bind(scope: TableFormulaScope(current: nil, visible: [t], inherited: [:])).first?
        .target == .namedColumn(table: t.id, column: t.columns[0].id))
    let plus = try #require(syntax.tokens.first { $0.kind == .plus })
    #expect(plus.range.text(in: source) == "+")
    #expect(plus.range.graphemeLowerBound == source.prefix { $0 != "+" }.count)
    #expect(throws: TableFormulaDiagnostic.self) {
      try TableFormulaSyntax.discover("=Items[Unit\\qprice]")
    }
  }

  @Test(arguments: [
    "$20 + B2", "5! + B2", "12:30 + B2", "12:99 + B2", "@3 + B2", "2 | B2", "20% of B2", "2 h + B2",
    "2024-10-03 + B2", "sqrt(B2)", "1 × B2", "1 · B2", "1 ÷ B2", "1 − B2", "1 << B2", "1 >> B2",
  ])
  func ordinaryCollisionCorpus(_ source: String) throws {
    let syntax = try TableFormulaSyntax.discover("=" + source)
    #expect(syntax.references.count == 1)
    #expect(syntax.references[0].range.text(in: syntax.source) == "B2")
    #expect(try syntax.parse(context: sheetContext()).expression != nil)
  }

  @Test func timeCollisionPrecedenceAndQualifiedRows() throws {
    for source in ["=12:30", "=12:99", "=2:30:45"] {
      #expect(try TableFormulaSyntax.discover(source).references.isEmpty)
    }
    for source in ["=100:20", "=Items!12:30", "=$12:$30", "=2:2"] {
      #expect(try TableFormulaSyntax.discover(source).references.count == 1)
    }
  }

  @Test func bareAggregateShadowingResolvedBySharedParser() throws {
    for source in ["=sum + 1", "=count", "=previous", "=avg * 2"] {
      let syntax = try TableFormulaSyntax.discover(source)
      #expect(throws: TableFormulaDiagnostic.self) { try syntax.parse(context: sheetContext()) }
    }
    for (source, name) in [("=count + 1", "count"), ("=sum cost", "sum cost")] {
      #expect(
        try TableFormulaSyntax.discover(source).parse(
          context: sheetContext(), inheritedKinds: [name: .number]
        ).expression != nil)
    }
  }

  @Test func percentageChangeAndConversionContexts() throws {
    let percentage = try TableFormulaSyntax.discover("=percentage change from B2 to C2")
    #expect(percentage.references.count == 2)
    #expect(try percentage.parse(context: sheetContext()).expression != nil)
    for source in ["=B2 in m", "=B2 to m"] {
      let syntax = try TableFormulaSyntax.discover(source)
      #expect(syntax.references.count == 1)
    }
  }

  @Test func nestedPercentageContextsKeepTheirOwnRightOperands() throws {
    let source = "=percentage change from (percentage change from B2 to C2) to D2"
    let syntax = try TableFormulaSyntax.discover(source)
    #expect(syntax.references.map { $0.range.text(in: source) } == ["B2", "C2", "D2"])
    #expect(try syntax.parse(context: sheetContext()).expression != nil)
    let conversion = "=percentage change from (B2 to m) to C2"
    let converted = try TableFormulaSyntax.discover(conversion)
    #expect(converted.references.map { $0.range.text(in: conversion) } == ["B2", "C2"])

  }

  @Test func ordinaryAssistantPromptTextIsNotTableSyntax() throws {
    let source = "ask_assistant(Items[Amount] costs Rates!B2)"
    let syntax = try TableFormulaSyntax.discover(source, tableFormula: false)
    #expect(syntax.references.isEmpty)
    #expect(try syntax.parse(context: sheetContext()) == Parser(source: source).parse())
    let placeholder = try TableFormulaSyntax.discover(
      "ask_assistant(Cost {Items!B2})", tableFormula: false)
    #expect(placeholder.references.count == 1)
    #expect(try placeholder.parse(context: sheetContext()).expression != nil)
  }

  @Test func functionNamesWithDigitsRemainCallNames() throws {
    for source in ["=log2(8)", "=log10(100)", "=atan2(1,1)", "=custom2(B2)"] {
      let syntax = try TableFormulaSyntax.discover(source)
      #expect(syntax.references.count == (source.contains("B2") ? 1 : 0))
      #expect(try syntax.parse(context: sheetContext()).expression != nil)
    }
  }

  @Test func ordinaryLongTokensAreNotReferenceOverflows() throws {
    for source in ["=123456789012345678901234567890", "=abcdefghijklmnop"] {
      #expect(try TableFormulaSyntax.discover(source).references.isEmpty)
    }
    #expect(throws: TableFormulaDiagnostic.self) {
      try TableFormulaSyntax.discover("=abcdefghijklmnop2")
    }
    #expect(throws: TableFormulaDiagnostic.self) {
      try TableFormulaSyntax.discover("=2:123456789012345678901234567890")
    }
  }

  @Test func bareAggregateDiagnosticPointsToItsASTOperand() throws {
    let source = "=sum(B2) + total"
    do {
      _ = try TableFormulaSyntax.discover(source).parse(context: sheetContext())
      Issue.record("Expected bare total diagnostic")
    } catch let diagnostic as TableFormulaDiagnostic {
      #expect(diagnostic.code == .bareAggregate)
      #expect(diagnostic.range.text(in: source) == "total")
    }
  }

  @Test func ordinaryCorpusStillUsesSharedParser() throws {
    let context = try sheetContext()
    for source in [
      "$20", "5!", "12:30", "@3", "2 | 3", "20% of 200", "2 h", "sum(1, 2)", "2 + 3 =",
    ] {
      let ordinary = Parser(source: source, variables: ["b2": .number]).parse()
      let scoped = try TableFormulaSyntax.discover(source, tableFormula: false).parse(
        context: context, inheritedKinds: ["b2": .number])
      #expect(ordinary == scoped)
    }
  }
}
