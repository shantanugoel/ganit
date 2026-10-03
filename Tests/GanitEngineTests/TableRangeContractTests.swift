import Foundation
import Testing

@testable import GanitEngine

/// Task-3 contract evidence for table range aggregates, written from the plan
/// ("Cell input and values", "Addressing") and ADR 0016 rather than from the
/// implementation. Expected values come from the ordinary engine.
@Suite struct TableRangeContractTests {
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

  /// `row` is a zero-based data row index (A1 row = row + 2).
  private func address(_ table: TableModel, _ row: Int, _ column: Int) -> TableCellAddress {
    TableCellAddress(table: table.id, row: table.rows[row], column: table.columns[column].id)
  }

  private func calculate(
    _ table: TableModel, visible: [TableModel] = [],
    earlier: [TableID: TableCalculationSnapshot] = [:]
  ) throws -> TableCalculationSnapshot {
    try TableCalculator().calculate(
      table, scope: TableFormulaScope(current: table, visible: visible, inherited: [:]),
      context: sheetContext(), earlier: earlier)
  }

  private func number(_ value: Int) -> TableCellResult {
    .scalar(.number(.integer(IntegerValue(value))))
  }

  private func ordinary(_ source: String) throws -> TableCellResult {
    let expression = try #require(Parser(source: source).parse().expression)
    return .scalar(try Evaluator(context: sheetContext()).evaluate(expression))
  }

  private func failure(
    _ snapshot: TableCalculationSnapshot, _ address: TableCellAddress,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) -> TableCalculationFailure? {
    guard case .failure(let failure) = snapshot.result(at: address) else {
      Issue.record(
        "Expected failure, got \(String(describing: snapshot.result(at: address)))",
        sourceLocation: sourceLocation)
      return nil
    }
    return failure
  }

  /// A column of value cells in column B (index 1) with readers in column A.
  /// Readers occupy rows 0..<readers.count; members are in column B.
  private func readersOverColumnB(
    _ members: [String], readers: [String], headers: [String]? = nil
  ) -> TableModel {
    let rows = max(members.count, readers.count)
    return table(
      (0..<rows).map { row in
        [row < readers.count ? readers[row] : "", row < members.count ? members[row] : ""]
      }, headers: headers)
  }

  // MARK: - Range forms

  @Test func rectangleAggregatesAllFunctions() throws {
    // A: readers; B..D rows 2...6 hold 1...15 row-major.
    let readers = [
      "=sum(B2:D6)", "=average(B2:D6)", "=median(B2:D6)", "=min(B2:D6)", "=max(B2:D6)",
      "=count(B2:D6)",
    ]
    let table = table(
      (0..<readers.count).map { row in
        [readers[row]] + (0..<3).map { column in row < 5 ? "\(row * 3 + column + 1)" : "" }
      })
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(120))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(8))
    #expect(snapshot.result(at: address(table, 2, 0)) == number(8))
    #expect(snapshot.result(at: address(table, 3, 0)) == number(1))
    #expect(snapshot.result(at: address(table, 4, 0)) == number(15))
    #expect(snapshot.result(at: address(table, 5, 0)) == number(15))
  }

  @Test func wholeColumnAggregatesAllFunctions() throws {
    let readers = [
      "=sum(C:C)", "=average(C:C)", "=median(C:C)", "=min(C:C)", "=max(C:C)", "=count(C:C)",
    ]
    let members = ["4", "", "10", "1", "7", ""]
    let table = table((0..<readers.count).map { [readers[$0], "", members[$0]] })
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(22))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("22 / 4")))
    #expect(snapshot.result(at: address(table, 2, 0)) == (try ordinary("median(4, 10, 1, 7)")))
    #expect(snapshot.result(at: address(table, 3, 0)) == number(1))
    #expect(snapshot.result(at: address(table, 4, 0)) == number(10))
    #expect(snapshot.result(at: address(table, 5, 0)) == number(4))
  }

  @Test func wholeRowAggregatesAllFunctions() throws {
    // Row 2 holds members; readers live in row 3, outside row 2.
    let table = table([
      ["3", "9", "", "6", "12", ""],
      ["=sum(2:2)", "=average(2:2)", "=median(2:2)", "=min(2:2)", "=max(2:2)", "=count(2:2)"],
    ])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 1, 0)) == number(30))
    #expect(snapshot.result(at: address(table, 1, 1)) == (try ordinary("30 / 4")))
    #expect(snapshot.result(at: address(table, 1, 2)) == (try ordinary("median(3, 9, 6, 12)")))
    #expect(snapshot.result(at: address(table, 1, 3)) == number(3))
    #expect(snapshot.result(at: address(table, 1, 4)) == number(12))
    #expect(snapshot.result(at: address(table, 1, 5)) == number(4))
  }

  @Test func namedColumnAggregatesAllFunctions() throws {
    let readers = [
      "=sum(Items[Amount])", "=average(Items[Amount])", "=median(Items[Amount])",
      "=min(Items[Amount])", "=max(Items[Amount])", "=count(Items[Amount])",
    ]
    let members = ["5", "2", "", "11", "", "8"]
    let table = table(
      (0..<readers.count).map { [readers[$0], members[$0]] }, headers: ["Total", "Amount"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(26))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("26 / 4")))
    #expect(snapshot.result(at: address(table, 2, 0)) == (try ordinary("median(5, 2, 11, 8)")))
    #expect(snapshot.result(at: address(table, 3, 0)) == number(2))
    #expect(snapshot.result(at: address(table, 4, 0)) == number(11))
    #expect(snapshot.result(at: address(table, 5, 0)) == number(4))
  }

  @Test func qualifiedEarlierTableRanges() throws {
    let rates = table(
      [["Standard", "$2.50"], ["Express", "$4.00"], ["Overnight", "$9.25"], ["Bulk", "$1.00"]],
      name: "Rates", headers: ["Name", "Amount"], policies: [.text, .value])
    let ratesSnapshot = try calculate(rates)
    let items = table([
      [
        "=sum(Rates!B2:B4)", "=sum(Rates[Amount])", "=max(Rates!B:B)", "=count(Rates!A2:B5)",
        "=min(Rates[Amount])",
      ]
    ])
    let snapshot = try calculate(items, visible: [rates], earlier: [rates.id: ratesSnapshot])
    #expect(snapshot.result(at: address(items, 0, 0)) == (try ordinary("$2.50 + $4.00 + $9.25")))
    #expect(
      snapshot.result(at: address(items, 0, 1))
        == (try ordinary("$2.50 + $4.00 + $9.25 + $1.00")))
    #expect(snapshot.result(at: address(items, 0, 2)) == (try ordinary("$9.25")))
    // Text names in column A are excluded from count.
    #expect(snapshot.result(at: address(items, 0, 3)) == number(4))
    #expect(snapshot.result(at: address(items, 0, 4)) == (try ordinary("$1.00")))
  }

  @Test func qualifiedRangeFailureCarriesEarlierOrigin() throws {
    let rates = table([["1"], ["=1 / 0"], ["3"]], name: "Rates")
    let ratesSnapshot = try calculate(rates)
    let items = table([["=sum(Rates!A2:A4)", "=sum(Rates!A2:A2)"]])
    let snapshot = try calculate(items, visible: [rates], earlier: [rates.id: ratesSnapshot])
    guard let failed = failure(snapshot, address(items, 0, 0)) else { return }
    #expect(failed.origin.map(\.address) == [address(rates, 1, 0)])
    #expect(snapshot.result(at: address(items, 0, 1)) == number(1))
  }

  @Test func builtInAggregateNamesAreCaseInsensitive() throws {
    let readers = ["=SUM(B2:B4)", "=Sum(B2:B4)", "=sUm(B:B)", "=AVERAGE(B2:B4)", "=MAX(B:B)"]
    let table = readersOverColumnB(["2", "4", "9"], readers: readers)
    let snapshot = try calculate(table)
    for row in 0..<3 {
      #expect(snapshot.result(at: address(table, row, 0)) == number(15))
    }
    #expect(snapshot.result(at: address(table, 3, 0)) == number(5))
    #expect(snapshot.result(at: address(table, 4, 0)) == number(9))
  }

  // MARK: - Membership

  @Test func wholeColumnExcludesHeaderAndTotals() throws {
    var table = readersOverColumnB(
      ["10", "20", "30"], readers: ["=sum(B:B)", "=count(B:B)", "=min(B:B)"],
      headers: ["Reader", "100"])
    // A numeric-looking header and a configured totals footer stay outside.
    table.columns[1].total = .sum
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(60))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(3))
    #expect(snapshot.result(at: address(table, 2, 0)) == number(10))
  }

  @Test func namedColumnGrowsWithAppendedRowButRectangleDoesNot() throws {
    var table = table(
      [["=sum(Items[Amount])", "1"], ["=sum(B2:B3)", "2"], ["=sum(B:B)", "3"]],
      headers: ["Reader", "Amount"])
    let before = try calculate(table)
    #expect(before.result(at: address(table, 0, 0)) == number(6))
    #expect(before.result(at: address(table, 1, 0)) == number(3))
    #expect(before.result(at: address(table, 2, 0)) == number(6))

    let added = RowID.mint()
    table.rows.append(added)
    table.cells.append(TableCell(row: added, column: table.columns[1].id, source: "40"))
    let after = try calculate(table)
    #expect(after.result(at: address(table, 0, 0)) == number(46))
    #expect(after.result(at: address(table, 1, 0)) == number(3))
    #expect(after.result(at: address(table, 2, 0)) == number(46))
  }

  // MARK: - Blank, text and failed members

  @Test func blankAndTextMembersAreSkipped() throws {
    // B5 is a formula yielding header text, B4 is blank; A is a text column.
    let table = table(
      [
        ["north", "4", "=sum(A2:B6)"],
        ["south", "", "=average(A2:B6)"],
        ["", "10", "=median(A2:B6)"],
        ["west", "=A1", "=min(A2:B6)"],
        ["east", "1", "=max(A2:B6)"],
      ], policies: [.text, .value, .value])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 3, 1)) == .text("Field0"))
    #expect(snapshot.result(at: address(table, 0, 2)) == number(15))
    #expect(snapshot.result(at: address(table, 1, 2)) == number(5))
    #expect(snapshot.result(at: address(table, 2, 2)) == number(4))
    #expect(snapshot.result(at: address(table, 3, 2)) == number(1))
    #expect(snapshot.result(at: address(table, 4, 2)) == number(10))
  }

  @Test func failedMemberFailsEveryAggregateWithOriginalOrigin() throws {
    let readers = [
      "=sum(B:B)", "=average(B:B)", "=median(B:B)", "=min(B:B)", "=max(B:B)", "=count(B:B)",
      "=sum(B2:B3)",
    ]
    let table = readersOverColumnB(["5", "=1 / 0", "7"], readers: readers)
    let snapshot = try calculate(table)
    let failedMember = address(table, 1, 1)
    #expect(failure(snapshot, failedMember)?.code == .evaluation)
    for row in 0..<readers.count {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      // Never collapses to zero or empty; the cause is the member, not the reader.
      #expect(failed.code == .blocked)
      #expect(failed.origin.map(\.address) == [failedMember])
    }
  }

  // MARK: - Typed values

  @Test func exactMoneySumMatchesOrdinaryEngine() throws {
    let table = readersOverColumnB(
      ["$0.10", "$0.10", "$0.10"], readers: ["=sum(B:B)", "=average(B:B)"])
    let snapshot = try calculate(table)
    let sum = snapshot.result(at: address(table, 0, 0))
    #expect(sum == (try ordinary("$0.10 + $0.10 + $0.10")))
    #expect(sum == (try ordinary("$0.30")))
    guard case .scalar(.money(let money)) = sum else {
      Issue.record("Expected money, got \(String(describing: sum))")
      return
    }
    #expect(money.currency == "USD")
    if case .approximate = money.amount { Issue.record("Money sum lost exactness") }
    #expect(
      snapshot.result(at: address(table, 1, 0))
        == (try ordinary("average($0.10, $0.10, $0.10)")))
  }

  @Test func mixedCurrenciesFailWithoutImplicitConversion() throws {
    let readers = ["=sum(B:B)", "=min(B:B)", "=max(B:B)", "=average(B:B)", "=median(B:B)"]
    let table = readersOverColumnB(["$5", "€2", "$1"], readers: readers)
    let snapshot = try calculate(table)
    for row in 0..<readers.count {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      // A currency mismatch is an evaluation error, not an unsupported range.
      #expect(failed.code == .evaluation, "row \(row): \(failed.code)")
      #expect(failed.engineError != nil)
      #expect(failed.origin.map(\.address) == [address(table, row, 0)])
    }
    // Control: a single-currency subrange of the same column still sums.
    let control = readersOverColumnB(["$5", "€2", "$1"], readers: ["=sum(B2:B2)", "=min(B3:B3)"])
    let controlSnapshot = try calculate(control)
    #expect(controlSnapshot.result(at: address(control, 0, 0)) == (try ordinary("$5")))
    #expect(controlSnapshot.result(at: address(control, 1, 0)) == (try ordinary("€2")))
  }

  @Test func moneyMixedWithPlainNumberFails() throws {
    let table = readersOverColumnB(
      ["$5", "2"], readers: ["=sum(B:B)", "=max(B:B)", "=sum(B2:B2)"])
    let snapshot = try calculate(table)
    for row in 0..<2 {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      #expect(failed.code == .evaluation, "row \(row): \(failed.code)")
    }
    #expect(snapshot.result(at: address(table, 2, 0)) == (try ordinary("$5")))
  }

  @Test func compatibleUnitsSumAndIncompatibleDimensionsFail() throws {
    let compatible = readersOverColumnB(
      ["1 m", "50 cm", "25 mm"], readers: ["=sum(B:B)", "=average(B:B)"])
    let snapshot = try calculate(compatible)
    #expect(snapshot.result(at: address(compatible, 0, 0)) == (try ordinary("1 m + 50 cm + 25 mm")))
    #expect(
      snapshot.result(at: address(compatible, 1, 0))
        == (try ordinary("average(1 m, 50 cm, 25 mm)")))

    let readers = ["=sum(B:B)", "=min(B:B)", "=max(B:B)", "=average(B:B)", "=median(B:B)"]
    let incompatible = readersOverColumnB(
      ["1 m", "2 kg"], readers: readers + ["=min(B2:B2)"])
    let failed = try calculate(incompatible)
    for row in 0..<readers.count {
      guard let failure = failure(failed, address(incompatible, row, 0)) else { continue }
      #expect(failure.code == .evaluation, "row \(row): \(failure.code)")
    }
    #expect(failed.result(at: address(incompatible, readers.count, 0)) == (try ordinary("1 m")))
  }

  @Test func typedMinAndMaxForMoney() throws {
    let table = readersOverColumnB(
      ["$12.50", "$0.99", "$100", "$7"], readers: ["=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("$0.99")))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("$100")))
  }

  @Test func typedMinAndMaxCompareQuantitiesAcrossCompatibleUnits() throws {
    // Numerically 50 > 1, but 1 m > 50 cm; a numeric-only path gets this wrong.
    let table = readersOverColumnB(["1 m", "50 cm", "0.9 m"], readers: ["=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(table)
    let minimum = snapshot.result(at: address(table, 0, 0))
    let maximum = snapshot.result(at: address(table, 1, 0))
    // Compare by converting to a fixed unit via the ordinary engine.
    guard case .scalar(let minimumValue) = minimum, case .scalar(let maximumValue) = maximum else {
      Issue.record(
        "Expected quantities, got \(String(describing: minimum)), \(String(describing: maximum))")
      return
    }
    guard case .quantity = minimumValue, case .quantity = maximumValue else {
      Issue.record("Expected quantities, got \(minimumValue), \(maximumValue)")
      return
    }
    #expect(try isEqualAfterSubtraction(minimumValue, "50 cm"))
    #expect(try isEqualAfterSubtraction(maximumValue, "1 m"))
  }

  /// `value - expected` is a zero quantity in the ordinary engine, so the two
  /// are equal regardless of the unit each is expressed in.
  private func isEqualAfterSubtraction(_ value: EngineValue, _ expected: String) throws -> Bool {
    let difference = try #require(Parser(source: "a - (\(expected))").parse().expression)
    let result = try Evaluator(
      context: sheetContext(), limits: .default, variables: ["a": value], lines: LineOutcomes()
    ).evaluate(difference)
    guard case .quantity(let quantity) = result else { return false }
    return quantity.magnitude.isZero
  }

  @Test func typedMinAndMaxForDatesAndTimes() throws {
    let dates = readersOverColumnB(
      ["2024-03-09", "2023-12-31", "2024-11-02"],
      readers: ["=min(B:B)", "=max(B:B)", "=count(B:B)", "=sum(B:B)"])
    let snapshot = try calculate(dates)
    #expect(snapshot.result(at: address(dates, 0, 0)) == (try ordinary("2023-12-31")))
    #expect(snapshot.result(at: address(dates, 1, 0)) == (try ordinary("2024-11-02")))
    #expect(snapshot.result(at: address(dates, 2, 0)) == number(3))
    // Dates have no additive sum; this must be diagnosed, not coerced.
    _ = failure(snapshot, address(dates, 3, 0))

    let times = readersOverColumnB(
      ["09:15", "17:30", "08:05"], readers: ["=min(B:B)", "=max(B:B)"])
    let timeSnapshot = try calculate(times)
    #expect(timeSnapshot.result(at: address(times, 0, 0)) == (try ordinary("08:05")))
    #expect(timeSnapshot.result(at: address(times, 1, 0)) == (try ordinary("17:30")))
  }

  @Test func percentageAggregates() throws {
    let table = readersOverColumnB(
      ["10%", "25%", "5%"], readers: ["=sum(B:B)", "=average(B:B)", "=min(B:B)", "=max(B:B)"])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("10% + 25% + 5%")))
    #expect(snapshot.result(at: address(table, 1, 0)) == (try ordinary("average(10%, 25%, 5%)")))
    #expect(snapshot.result(at: address(table, 2, 0)) == (try ordinary("5%")))
    #expect(snapshot.result(at: address(table, 3, 0)) == (try ordinary("25%")))
  }

  // MARK: - Empty ranges

  @Test func emptyNumericSumIsZeroAndOtherEmptyAggregatesFail() throws {
    let readers = [
      "=sum(B:B)", "=average(B:B)", "=median(B:B)", "=min(B:B)", "=max(B:B)", "=count(B:B)",
    ]
    let table = readersOverColumnB([], readers: readers)
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == number(0))
    for row in 1...4 {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      #expect(failed.origin.map(\.address) == [address(table, row, 0)])
    }
    #expect(snapshot.result(at: address(table, 5, 0)) == number(0))
  }

  @Test func allTextRangeIsEmptyForAggregates() throws {
    let table = table(
      [["north", "=sum(A:A)"], ["south", "=average(A:A)"], ["", "=max(A:A)"]],
      policies: [.text, .value])
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 1)) == number(0))
    _ = failure(snapshot, address(table, 1, 1))
    _ = failure(snapshot, address(table, 2, 1))
  }

  @Test func emptyTypedColumnsSumToTypedZero() throws {
    var money = readersOverColumnB([], readers: ["=sum(B:B)", "=average(B:B)"])
    money.columns[1].currency = "USD"
    let moneySnapshot = try calculate(money)
    guard case .scalar(.money(let zero)) = moneySnapshot.result(at: address(money, 0, 0)) else {
      Issue.record(
        "Expected typed money zero, got \(String(describing: moneySnapshot.result(at: address(money, 0, 0))))"
      )
      return
    }
    #expect(zero.currency == "USD")
    #expect(zero.amount.isZero)
    _ = failure(moneySnapshot, address(money, 1, 0))

    var length = readersOverColumnB([], readers: ["=sum(B:B)", "=min(B:B)"])
    length.columns[1].unit = "m"
    let lengthSnapshot = try calculate(length)
    guard case .scalar(.quantity(let quantity)) = lengthSnapshot.result(at: address(length, 0, 0))
    else {
      Issue.record(
        "Expected typed quantity zero, got \(String(describing: lengthSnapshot.result(at: address(length, 0, 0))))"
      )
      return
    }
    #expect(try isEqualAfterSubtraction(.quantity(quantity), "0 m"))
    _ = failure(lengthSnapshot, address(length, 1, 0))
  }

  @Test func typedDefaultColumnSumsInterpretedMembers() throws {
    var table = readersOverColumnB(["1.10", "", "2.20"], readers: ["=sum(B:B)"])
    table.columns[1].currency = "USD"
    let snapshot = try calculate(table)
    #expect(snapshot.result(at: address(table, 0, 0)) == (try ordinary("$1.10 + $2.20")))
  }

  // MARK: - count

  @Test func countRangeCountsTypedScalarsAndExcludesTextAndBlanks() throws {
    let table = table(
      [
        ["label", "5", "=count(A2:B8)"],
        ["", "$3", "=count(B:B)"],
        ["x", "2 m", "=count(1, 2, 3)"],
        ["", "2024-03-09", "=count(2:2)"],
        ["y", "=A1", ""],
        ["", "", ""],
        ["", "17:30", ""],
      ], policies: [.text, .value, .value])
    let snapshot = try calculate(table)
    // 5, $3, 2 m, date, time; text in A, header text in B6 and blanks excluded.
    #expect(snapshot.result(at: address(table, 0, 2)) == number(5))
    #expect(snapshot.result(at: address(table, 1, 2)) == number(5))
    #expect(snapshot.result(at: address(table, 2, 2)) == (try ordinary("count(1, 2, 3)")))
    #expect(snapshot.result(at: address(table, 2, 2)) == number(3))
    // Row 2 holds text `label`, `5` and C2's count result (5).
    #expect(snapshot.result(at: address(table, 3, 2)) == number(2))
  }

  @Test func countFailsOnFormulaError() throws {
    let table = readersOverColumnB(
      ["1", "=1 / 0", "3"], readers: ["=count(B:B)", "=count(B2:B2)"])
    let snapshot = try calculate(table)
    let failed = failure(snapshot, address(table, 0, 0))
    #expect(failed?.origin.map(\.address) == [address(table, 1, 1)])
    #expect(snapshot.result(at: address(table, 1, 0)) == number(1))
  }

  // MARK: - Diagnostics

  @Test func rangeInScalarArithmeticIsDiagnosed() throws {
    let sources = ["=B2:B4 + 1", "=B:B * 2", "=Items[Amount]", "=2:2 + 0", "=sum(B2:B4)"]
    let table = table(
      [
        [sources[0], "1"], [sources[1], "2"], [sources[2], "3"], [sources[3], ""],
        [sources[4], ""],
      ],
      headers: ["Reader", "Amount"])
    let snapshot = try calculate(table)
    for row in 0..<3 {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      #expect(
        [.scalarRequired, .unsupportedRangeOperation, .reference].contains(failed.code),
        "row \(row): \(failed.code)")
      #expect(failed.origin.map(\.address) == [address(table, row, 0)])
    }
    // `2:2` also contains A2's failure; either way A5 must not be a value.
    _ = failure(snapshot, address(table, 3, 0))
    #expect(snapshot.result(at: address(table, 4, 0)) == number(6))
  }

  @Test func bareAggregatesAndPreviousAreDiagnosed() throws {
    let sources = ["=sum", "=SUM", "=previous", "=1 + total", "=average", "=sum()"]
    let table = table([sources])
    let snapshot = try calculate(table)
    for column in 0..<sources.count {
      guard let failed = failure(snapshot, address(table, 0, column)) else { continue }
      #expect(failed.code != .blocked, "column \(column)")
      #expect(failed.origin.map(\.address) == [address(table, 0, column)])
    }
    for column in 0..<5 {
      guard case .failure(let failed) = snapshot.result(at: address(table, 0, column)) else {
        continue
      }
      #expect(failed.referenceDiagnostic?.code == .bareAggregate, "column \(column)")
    }
  }

  @Test func unsupportedFunctionOverRangeIsDiagnosed() throws {
    let sources = [
      "=sqrt(B2:B4)", "=abs(B:B)", "=round(Items[Amount])", "=ln(B2:B3)", "=sum(B2:B5)",
    ]
    let table = table(
      (0..<5).map { [sources[$0], $0 < 4 ? "\($0 + 1)" : ""] }, headers: ["Reader", "Amount"])
    let snapshot = try calculate(table)
    for row in 0..<4 {
      guard let failed = failure(snapshot, address(table, row, 0)) else { continue }
      #expect(failed.code != .blocked, "row \(row)")
      #expect(failed.code != .cycle, "row \(row)")
      #expect(failed.origin.map(\.address) == [address(table, row, 0)])
    }
    #expect(snapshot.result(at: address(table, 4, 0)) == number(10))
  }

  // MARK: - Cycles

  @Test func wholeColumnSelfMembershipIsACycle() throws {
    let table = table([["=sum(A:A)", "1"], ["4", "=B2 + 1"]])
    let snapshot = try calculate(table)
    let reader = address(table, 0, 0)
    guard let cycle = failure(snapshot, reader) else { return }
    #expect(cycle.code == .cycle)
    #expect(cycle.cycleParticipants.contains(reader))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(4))
    #expect(snapshot.result(at: address(table, 1, 1)) == number(2))
  }

  @Test func wholeRowSelfMembershipIsACycle() throws {
    let table = table([["5", "=sum(2:2)", "7"], ["1", "=sum(3:3) * 0 + A3", "2"]])
    let snapshot = try calculate(table)
    guard let cycle = failure(snapshot, address(table, 0, 1)) else { return }
    #expect(cycle.code == .cycle)
    #expect(cycle.cycleParticipants.contains(address(table, 0, 1)))
    // Independent cells in the same row are not participants and still calculate.
    #expect(snapshot.result(at: address(table, 0, 0)) == number(5))
    #expect(snapshot.result(at: address(table, 0, 2)) == number(7))
    #expect(!cycle.cycleParticipants.contains(address(table, 0, 0)))
    #expect(snapshot.result(at: address(table, 1, 0)) == number(1))
  }

  @Test func namedColumnSelfMembershipIsACycle() throws {
    let table = table([["=sum(Items[Amount])"], ["3"]], headers: ["Amount"])
    let snapshot = try calculate(table)
    #expect(failure(snapshot, address(table, 0, 0))?.code == .cycle)
    #expect(snapshot.result(at: address(table, 1, 0)) == number(3))
  }

  // MARK: - Shared range readers

  @Test func thousandReadersShareOneRangeNode() throws {
    let rows = 1_000
    var table = table((0..<rows).map { ["", "\($0 + 1)"] })
    table.columns[0].rule = "=B2 / sum(B:B)"
    let snapshot = try calculate(table)
    let total = rows * (rows + 1) / 2
    for row in [0, 1, 499, 998, 999] {
      #expect(
        snapshot.result(at: address(table, row, 0)) == (try ordinary("\(row + 1) / \(total)")),
        "row \(row)")
    }
    var correct = 0
    for row in 0..<rows {
      if snapshot.result(at: address(table, row, 0)) == (try ordinary("\(row + 1) / \(total)")) {
        correct += 1
      }
    }
    #expect(correct == rows)
    let ranges = snapshot.nodes.filter {
      if case .range = $0 { return true }
      return false
    }
    #expect(ranges.count == 1)
    let range = try #require(
      snapshot.nodes.firstIndex {
        if case .range = $0 { return true }
        return false
      })
    #expect(snapshot.reverseDependencies[range].count == rows)
    #expect(snapshot.dependencies[range].count == rows)
  }
}
