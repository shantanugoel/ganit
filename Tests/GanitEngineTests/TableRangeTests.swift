import Foundation
import Testing

@testable import GanitEngine

/// Implementation corpus for M2 task 3: range reductions, typed min/max,
/// empty/typed-zero rules, shared reductions and case-insensitive built-ins.
@Suite struct TableRangeTests {
  private func table(
    _ inputs: [[String]], name: String = "Items", headers: [String]? = nil,
    policies: [TableInputPolicy]? = nil
  ) -> TableModel {
    let columns = max(inputs.map(\.count).max() ?? 1, headers?.count ?? 0)
    var table = TableModel.creating(
      name: name,
      headers: (0..<columns).map { (headers?[$0] ?? "Field\($0)", policies?[$0] ?? .value) },
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
    _ table: TableModel, visible: [TableModel] = [], inherited: [String: EngineValue?] = [:],
    earlier: [TableID: TableCalculationSnapshot] = [:]
  ) throws -> TableCalculationSnapshot {
    try TableCalculator().calculate(
      table, scope: TableFormulaScope(current: table, visible: visible, inherited: inherited),
      context: sheetContext(), earlier: earlier)
  }

  private func ordinary(_ source: String) throws -> TableCellResult {
    let expression = try #require(Parser(source: source).parse().expression)
    return .scalar(try Evaluator(context: sheetContext()).evaluate(expression))
  }

  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }

  private func code(
    _ snapshot: TableCalculationSnapshot, _ address: TableCellAddress
  ) -> TableCalculationFailure.Code? {
    if case .failure(let failure) = snapshot.result(at: address) { return failure.code }
    return nil
  }

  /// Members in column B; readers in column A.
  private func readers(_ members: [String], _ formulas: [String]) -> TableModel {
    table(
      (0..<max(members.count, formulas.count)).map {
        [$0 < formulas.count ? formulas[$0] : "", $0 < members.count ? members[$0] : ""]
      })
  }

  // MARK: - Typed min/max audit

  @Test func minAndMaxSelectTheMemberUnchanged() throws {
    // 100 cm and 1 m tie; the first in row order wins and keeps its unit.
    let lengths = readers(["100 cm", "1 m", "2 km", "30 m"], ["=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(lengths)
    #expect(snapshot.result(at: address(lengths, 0, 0)) == (try ordinary("100 cm")))
    #expect(snapshot.result(at: address(lengths, 1, 0)) == (try ordinary("2 km")))
    let ties = readers(["100 cm", "1 m"], ["=min(B:B)", "=max(B:B)"])
    let tieSnapshot = try calculate(ties)
    #expect(tieSnapshot.result(at: address(ties, 0, 0)) == (try ordinary("100 cm")))
    #expect(tieSnapshot.result(at: address(ties, 1, 0)) == (try ordinary("100 cm")))
  }

  @Test func exactNumericMinAndMaxStayExact() throws {
    let table = readers(["=1/3", "0.3333", "-2.5"], ["=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("-2.5")))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("1/3")))
  }

  @Test func approximateMemberKeepsItsProvenance() throws {
    let table = readers(["=sqrt(2)", "1"], ["=max(B:B)", "=min(B:B)"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("sqrt(2)")))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(1))
  }

  @Test func moneyMinMaxRejectsMixedCurrencyAndPlainNumbers() throws {
    let mixed = readers(["$5", "4 EUR"], ["=min(B:B)", "=max(B:B)", "=sum(B:B)"])
    let snapshot = try calculate(mixed)
    for row in 0..<3 {
      guard case .failure(let failure) = snapshot.result(at: address(mixed, row, 0)) else {
        Issue.record("row \(row) should fail")
        continue
      }
      #expect(failure.code == .evaluation)
      #expect(failure.engineError?.code == .mixedCurrencies)
    }
    let plain = readers(["$5", "4"], ["=max(B:B)"])
    let plainSnapshot = try calculate(plain)
    guard case .failure(let failure) = plainSnapshot.result(at: address(plain, 0, 0)) else {
      Issue.record("money and number must not order")
      return
    }
    #expect(failure.engineError?.code == .typeMismatch)
  }

  @Test func quantityMinMaxRejectsIncompatibleDimensions() throws {
    let table = readers(["1 m", "2 kg"], ["=min(B:B)"])
    let snapshot = try calculate(table)
    guard case .failure(let failure) = snapshot.result(at: address(table, 0, 0)) else {
      Issue.record("incompatible dimensions must fail")
      return
    }
    #expect(failure.engineError?.code == .incompatibleDimensions)
    // The failure points at the reader's own call, not at a member.
    #expect(failure.sourceRange.lowerBound == 1)
    #expect(failure.origin.map(\.address) == [address(table, 0, 0)])
  }

  @Test func periodsOrderOnlyWhenEveryMonthLengthAgrees() throws {
    let comparable = readers(["1 month", "3 months", "2 months"], ["=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(comparable)
    #expect(snapshot.result(at: address(comparable, 0, 0)) == (try ordinary("1 month")))
    #expect(snapshot.result(at: address(comparable, 1, 0)) == (try ordinary("3 months")))
    // Months bound days (28 to 31 per month): these pairs are unambiguous.
    let bounded = readers(["20 days", "1 month", "45 days"], ["=max(B2:B3)", "=max(B3:B4)"])
    let boundedSnapshot = try calculate(bounded)
    #expect(boundedSnapshot.result(at: address(bounded, 0, 0)) == (try ordinary("1 month")))
    #expect(boundedSnapshot.result(at: address(bounded, 1, 0)) == (try ordinary("45 days")))
    // 30 days may be shorter or longer than a month.
    let ambiguous = readers(["1 month", "30 days"], ["=max(B:B)"])
    guard
      case .failure(let failure) = (try calculate(ambiguous)).result(at: address(ambiguous, 0, 0))
    else {
      Issue.record("1 month and 30 days do not order")
      return
    }
    #expect(failure.engineError?.code == .invalidDomain)
  }

  @Test func temporalMedianAndAverageAreDiagnosedNotCoerced() throws {
    let table = readers(
      ["2024-01-01", "2024-02-01", "2024-03-01"], ["=median(B:B)", "=average(B:B)"])
    let snapshot = try calculate(table)
    #expect(code(snapshot, address(table, 0, 0)) == .evaluation)
    #expect(code(snapshot, address(table, 1, 0)) == .evaluation)
  }

  // MARK: - Ordinary arithmetic reuse

  @Test func aggregatesMatchOrdinaryEngine() throws {
    // B5 `text?` is not a value literal, so it is a failed member.
    let model = readers(
      ["$1.10", "$2.20", "$0.70", "text?"],
      ["=sum(B2:B4)", "=average(B2:B4)", "=median(B2:B4)", "=total(B:B)", "=AVG(B:B)"])
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 0)) == (try ordinary("$1.10 + $2.20 + $0.70")))
    #expect(
      snapshot.result(at: address(model, 1, 0)) == (try ordinary("average($1.10, $2.20, $0.70)")))
    #expect(snapshot.result(at: address(model, 2, 0)) == (try ordinary("$1.10")))
    // The failed member blocks only whole-column readers.
    #expect(code(snapshot, address(model, 3, 0)) == .blocked)
    #expect(code(snapshot, address(model, 4, 0)) == .blocked)
  }

  @Test func compatibleUnitMedianAndSumConvert() throws {
    let table = readers(["1 m", "50 cm", "3 m"], ["=median(B:B)", "=sum(B:B)"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("1 m")))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("1 m + 50 cm + 3 m")))
  }

  @Test func aggregateResultCombinesInFurtherArithmetic() throws {
    let table = readers(["2", "4", "9"], ["=sum(B:B) / count(B:B) + max(B2:B3) * 2"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("15 / 3 + 4 * 2")))
  }

  // MARK: - Empty and typed zero

  @Test func emptySumTypedZeroRules() throws {
    // A unit column with an additive zero, a period column, and disagreeing
    // currency defaults across a rectangle.
    var model = table(
      [
        ["=sum(B:B)", "", "", "", ""], ["=sum(C:C)", "", "", "", ""],
        ["=sum(D2:E3)", "", "", "", ""], ["=sum(B2:C5)", "", "", "", ""],
      ])
    model.columns[1].unit = "kg"
    model.columns[2].unit = "days"
    model.columns[3].currency = "USD"
    model.columns[4].currency = "EUR"
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 0)) == (try ordinary("0 kg")))
    #expect(snapshot.result(at: address(model, 1, 0)) == (try ordinary("0 days")))
    #expect(code(snapshot, address(model, 2, 0)) == .unsupportedAggregation)
    #expect(code(snapshot, address(model, 3, 0)) == .unsupportedAggregation)
  }

  @Test func textColumnsDeclareNoZero() throws {
    var model = table(
      [["north", "", "=sum(A2:B3)"], ["south", "", "=average(A2:B3)"]],
      policies: [.text, .value, .value])
    model.columns[1].currency = "USD"
    let snapshot = try calculate(model)
    guard case .scalar(.money(let zero)) = snapshot.result(at: address(model, 0, 2)) else {
      Issue.record(
        "expected USD zero, got \(String(describing: snapshot.result(at: address(model, 0, 2))))")
      return
    }
    #expect(zero.currency == "USD" && zero.amount.isZero)
    #expect(code(snapshot, address(model, 1, 2)) == .emptyRange)
  }

  @Test func emptyRangeDiagnosticsUseDedicatedCode() throws {
    let table = readers(["", ""], ["=average(B:B)", "=min(B2:B3)", "=count(B:B)"])
    let snapshot = try calculate(table)
    #expect(code(snapshot, address(table, 0, 0)) == .emptyRange)
    #expect(code(snapshot, address(table, 1, 0)) == .emptyRange)
    #expect(snapshot.result(at: address(table, 2, 0)) == number(0))
  }

  // MARK: - Membership

  @Test func wholeRowCoversAllColumnsOfThatDataRow() throws {
    let model = table([["1", "2", "3", ""], ["4", "x", "=sum(2:2)", "=sum(A:B)"]])
    // C3 reads data row 2 only; D3 reads B3's invalid literal `x`.
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 1, 2)) == number(6))
    #expect(code(snapshot, address(model, 1, 3)) == .blocked)
  }

  @Test func ruleTemplateRangesTranslatePerRow() throws {
    var model = table([["1", ""], ["2", ""], ["3", ""]])
    model.columns[1].rule = "=sum($A$2:A2)"
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 1)) == number(1))
    #expect(snapshot.result(at: address(model, 1, 1)) == number(3))
    #expect(snapshot.result(at: address(model, 2, 1)) == number(6))
  }

  @Test func qualifiedEarlierRangeReadsEarlierSnapshot() throws {
    var rates = table([["$2"], ["$3"], [""]], name: "Rates", headers: ["Amount"])
    rates.columns[0].currency = "USD"
    let ratesSnapshot = try calculate(rates)
    let items = table([["=sum(Rates[Amount]) + max(Rates!A2:A4)", "=COUNT(Rates!A:A)"]])
    let snapshot = try calculate(
      items, visible: [rates], earlier: [rates.id: ratesSnapshot])
    #expect(snapshot.result(at: address(items, 0, 0)) == (try ordinary("$2 + $3 + $3")))
    #expect(snapshot.result(at: address(items, 0, 1)) == number(2))
  }

  // MARK: - Diagnostics

  @Test func rangesOutsideSupportedAggregatesAreTheReadersOwnError() throws {
    let model = readers(
      ["1", "2"],
      [
        "=B2:B3", "=B2:B3 + 1", "=abs(B2:B3)", "=sum(B2:B3, 1)", "=sum(B2:B3, B2:B3)",
        "=nosuch(B2:B3)", "=sum(B2:B3 * 2)",
      ])
    let snapshot = try calculate(model)
    for row in 0..<7 {
      #expect(code(snapshot, address(model, row, 0)) == .unsupportedRangeOperation, "row \(row)")
    }
  }

  @Test func uppercaseBareKeywordsAreDiagnosedButInheritedNamesAreNot() throws {
    let model = table([["=SUM", "=Previous", "=TOTAL + 1", "=Count"]])
    let snapshot = try calculate(model, inherited: ["total": .number(.integer(IntegerValue(5)))])
    for column in [0, 1, 3] {
      guard case .failure(let failure) = snapshot.result(at: address(model, 0, column)) else {
        Issue.record("column \(column) should fail")
        continue
      }
      #expect(failure.referenceDiagnostic?.code == .bareAggregate, "column \(column)")
    }
    #expect(snapshot.result(at: address(model, 0, 2)) == number(6))
  }

  @Test func builtInsAreCaseInsensitiveOnlyInTableFormulas() throws {
    let model = readers(["4", "9"], ["=SQRT(B3) + Max(B:B) + ROUND(2.5)", "=Sum(1, 2)"])
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 0)) == (try ordinary("sqrt(9) + 9 + round(2.5)")))
    #expect(snapshot.result(at: address(model, 1, 0)) == number(3))
    // Ordinary sheet dispatch is unchanged.
    let expression = try #require(Parser(source: "SQRT(9)").parse().expression)
    #expect(throws: EngineError.self) {
      try Evaluator(context: sheetContext()).evaluate(expression)
    }
  }

  @Test func outOfBoundsRangeIsAReferenceFailureNotEmpty() throws {
    let model = readers(["1"], ["=sum(B2:B9)", "=sum(Z:Z)", "=sum(7:7)"])
    let snapshot = try calculate(model)
    for row in 0..<3 {
      guard case .failure(let failure) = snapshot.result(at: address(model, row, 0)) else {
        Issue.record("row \(row) should fail")
        continue
      }
      #expect(failure.code == .reference)
      #expect(failure.referenceDiagnostic?.code == .outOfBounds)
    }
  }

  // MARK: - Shared reductions

  @Test func manyReadersReduceASharedRangeOncePerFunction() throws {
    let rows = 400
    let model = table(
      (0..<rows).map { row in
        ["\(row + 1)", row.isMultiple(of: 2) ? "=sum(A:A) + 0" : "=max($A$2:$A$401) - 1"]
      })
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 1)) == number(rows * (rows + 1) / 2))
    #expect(snapshot.result(at: address(model, 1, 1)) == number(rows - 1))
    // Two range nodes, one function each: each member is visited once per node.
    #expect(snapshot.rangeCellVisits == 2 * rows)
    let rangeNodes = snapshot.nodes.filter {
      if case .range = $0 { return true }
      return false
    }
    #expect(rangeNodes.count == 2)
  }

  @Test func sameRangeWithDifferentFunctionsReducesPerFunction() throws {
    let model = readers(["1", "2", "3"], ["=sum(B:B) + count(B:B) + sum(B:B)"])
    let snapshot = try calculate(model)
    #expect(snapshot.result(at: address(model, 0, 0)) == number(15))
    // Members are collected once per node and shared across functions.
    #expect(snapshot.rangeCellVisits == 3)
  }

  // MARK: - Kind-directed parsing after reduction

  @Test func reducedKindDirectsPercentageAndUnitPhrases() throws {
    let percentages = table([
      ["=sum(B:B) of 200", "10%", "=B2 of 200"], ["=SUM(B:B) * 2", "5%", ""],
    ])
    let snapshot = try calculate(percentages)
    #expect(snapshot.result(at: address(percentages, 0, 0)) == (try ordinary("15% of 200")))
    #expect(snapshot.result(at: address(percentages, 0, 2)) == number(20))
    #expect(snapshot.result(at: address(percentages, 1, 0)) == (try ordinary("15% * 2")))
    // As in ordinary syntax, `of` binds tighter than `+`: 10% + 10 is a
    // type mismatch, not a syntax failure. Grouping sums first.
    let mixed = table([
      ["=sum(B2:B2) + sum(C2:C2) of 200", "10%", "5%"],
      ["=(sum(B2:B2) + sum(C2:C2)) of 200", "", ""],
    ])
    let mixedSnapshot = try calculate(mixed)
    guard case .failure(let ungrouped) = mixedSnapshot.result(at: address(mixed, 0, 0)) else {
      Issue.record("10% + 10 must fail as in the ordinary engine")
      return
    }
    #expect(ungrouped.engineError?.code == .typeMismatch)
    #expect(mixedSnapshot.result(at: address(mixed, 1, 0)) == (try ordinary("(10% + 5%) of 200")))
    let lengths = readers(["1 m", "50 cm"], ["=max(B:B) in cm", "=sum((B:B)) + 2 m"])
    let lengthSnapshot = try calculate(lengths)
    #expect(lengthSnapshot.result(at: address(lengths, 0, 0)) == (try ordinary("1 m in cm")))
    #expect(
      lengthSnapshot.result(at: address(lengths, 1, 0)) == (try ordinary("1 m + 50 cm + 2 m")))
  }

  @Test func aggregateFailureLocatesAtTheCallInOriginalSource() throws {
    let source = "=1 + max(B:B) of 200"
    let model = readers(["$1", "2 EUR"], [source])
    guard case .failure(let failure) = (try calculate(model)).result(at: address(model, 0, 0))
    else {
      Issue.record("mixed currencies must fail")
      return
    }
    #expect(failure.code == .evaluation)
    #expect(failure.engineError?.code == .mixedCurrencies)
    let call = try #require(source.range(of: "max(B:B)"))
    #expect(
      failure.sourceRange.lowerBound
        == source.utf8.distance(from: source.startIndex, to: call.lowerBound))
    #expect(
      failure.sourceRange.upperBound
        == source.utf8.distance(from: source.startIndex, to: call.upperBound))
  }

  @Test func blockedAggregateWithKindPhraseStaysBlocked() throws {
    // The static check collapses the call too: `of` is not a syntax error.
    let model = readers(["=1/0", "10%"], ["=sum(B:B) of 200"])
    #expect(code(try calculate(model), address(model, 0, 0)) == .blocked)
  }

  // MARK: - Custom functions and inherited names

  @Test func visibleCustomFunctionNamesAreNeverHijacked() throws {
    let model = readers(["1", "2"], ["=SUM(B:B)", "=MAX(1, 2)", "=Abs(-3)"])
    var calculator = TableCalculator()
    calculator.visibleCustomFunctionNames = ["sum", "max"]
    let snapshot = try calculator.calculate(
      model, scope: TableFormulaScope(current: model, visible: [], inherited: [:]),
      context: sheetContext())
    // A custom `sum` takes no range; `MAX` keeps its custom spelling.
    #expect(code(snapshot, address(model, 0, 0)) == .unsupportedRangeOperation)
    guard case .failure(let failure) = snapshot.result(at: address(model, 1, 0)) else {
      Issue.record("MAX must not dispatch to the built-in")
      return
    }
    #expect(failure.engineError?.code == .unknownFunction)
    #expect(snapshot.result(at: address(model, 2, 0)) == number(3))
  }

  @Test func failedInheritedKeywordNameIsInheritedFailure() throws {
    let model = table([["=TOTAL + 1", "=total + 1", "=SUM"]])
    let snapshot = try calculate(model, inherited: ["total": nil])
    for column in 0..<2 {
      guard case .failure(let failure) = snapshot.result(at: address(model, 0, column)) else {
        Issue.record("column \(column) should fail")
        continue
      }
      #expect(failure.referenceDiagnostic?.code == .inheritedFailure, "column \(column)")
    }
    guard case .failure(let bare) = snapshot.result(at: address(model, 0, 2)) else {
      Issue.record("bare SUM should fail")
      return
    }
    #expect(bare.referenceDiagnostic?.code == .bareAggregate)
  }

  @Test func emptySumOverUnitAndPlainColumnsIsUnsupported() throws {
    var model = table([["=sum(B:C)", "", ""]])
    model.columns[1].unit = "m"
    #expect(code(try calculate(model), address(model, 0, 0)) == .unsupportedAggregation)
  }

  @Test func ownSyntaxAndKeywordErrorsOutrankEmptyReductions() throws {
    let model = readers(
      ["", ""], ["=average(B2:B3) +", "=average(B2:B3) + SUM", "=10 min(B2:B3)", "=average(B2:B3)"])
    let snapshot = try calculate(model)
    #expect(code(snapshot, address(model, 0, 0)) == .syntax)
    guard case .failure(let bare) = snapshot.result(at: address(model, 1, 0)) else {
      Issue.record("bare SUM must fail")
      return
    }
    #expect(bare.referenceDiagnostic?.code == .bareAggregate)
    #expect(code(snapshot, address(model, 2, 0)) == .syntax)
    #expect(code(snapshot, address(model, 3, 0)) == .emptyRange)
  }
}
