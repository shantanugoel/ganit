import Foundation
import Testing

@testable import GanitEngine

/// M3 task 4: the read-only table result API and failure origins that lead
/// from a prose line to the original failing table cell.
@Suite struct TableResultSnapshotTests {
  typealias Fold = TableSheetFoldTests

  static func text(_ source: String, _ range: Range<Int>) -> String {
    String(decoding: Array(source.utf8)[range], as: UTF8.self)
  }

  @Test func textColumnErrorsExplainTheCauseAndRepair() throws {
    var items = Fold.table(
      "Items", headers: ["Item", "Qty", "Amount"],
      rows: [
        ["1", "3", "=A2+B2"], ["", "", "=sum(A2, B2)"],
        ["", "", "=sum(A2:B2)"], ["1", "", "=[@Item]+B2"],
      ])
    items.columns[0].input = .text
    var run = try Fold.Run()
    let result = try #require(try run.evaluate(Fold.block(items)).tableResult(items.id))
    let amount = items.columns[2].id
    for row in 0...1 {
      #expect(
        result.cellProblem(row: items.rows[row], column: amount)
          == "A2 contains text because column \"Item\" uses Text input. This formula requires a value. Change the column's Input Type to Automatic or Value."
      )
    }
    #expect(
      result.cellProblem(row: items.rows[3], column: amount)
        == "[@Item] contains text because column \"Item\" uses Text input. This formula requires a value. Change the column's Input Type to Automatic or Value."
    )
    #expect(
      result.value(row: items.rows[2], column: amount) == .value(.number(.integer(IntegerValue(3))))
    )
    #expect(
      result.problemRange(row: items.rows[0], column: amount) == NSRange(location: 1, length: 2))

    items.columns[0].input = .automatic
    let repaired = try #require(try run.evaluate(Fold.block(items)).tableResult(items.id))
    for row in 0...2 {
      #expect(
        repaired.value(row: items.rows[row], column: amount)
          == .value(.number(.integer(IntegerValue(4)))))
      #expect(repaired.cellProblem(row: items.rows[row], column: amount) == nil)
    }
  }

  @Test func scalarErrorsDistinguishTextHeadersAndBlankCells() throws {
    let items = Fold.table(
      "Items", headers: ["Item", "Amount"],
      rows: [["\"1\"", "=A2+3"], ["", "=A3+3"], ["", "=A1+3"]])
    var run = try Fold.Run()
    let result = try #require(try run.evaluate(Fold.block(items)).tableResult(items.id))
    let amount = items.columns[1].id
    #expect(
      result.cellProblem(row: items.rows[0], column: amount)
        == "A2 contains text. This formula requires a value. Replace the text with a number or another value."
    )
    #expect(
      result.cellProblem(row: items.rows[1], column: amount)
        == "A3 is blank. This formula requires a value. Enter a number or another value in that cell."
    )
    #expect(
      result.cellProblem(row: items.rows[2], column: amount)
        == "A1 refers to a column header, which contains text. This formula requires a value. Use a data cell from row 2 or below."
    )
  }

  @Test func textColumnErrorsUseTheReferencedTableSettings() throws {
    var codes = Fold.table("Codes", headers: ["Code"], rows: [["00123"]])
    codes.columns[0].input = .text
    let items = Fold.table("Items", headers: ["Amount"], rows: [["=Codes!A2+3"]])
    var run = try Fold.Run()
    let result = try #require(
      try run.evaluate(Fold.block(codes) + Fold.block(items)).tableResult(items.id))
    #expect(
      result.cellProblem(row: items.rows[0], column: items.columns[0].id)
        == "Codes!A2 contains text because column \"Code\" uses Text input. This formula requires a value. Change the column's Input Type to Automatic or Value."
    )
  }

  @Test func resultsAreKeyedByIdentityAndSourceSpan() throws {
    let items = Fold.items()
    let quarantined = "@ganit-table 9\n{}\n@end-ganit-table\n"
    let source = "rate = 3\n" + (try Fold.block(items)) + quarantined + "Items!B3\n"
    var run = try Fold.Run()
    let evaluation = try run.evaluate(source)
    let results = evaluation.tableResults
    #expect(results.map(\.id) == [items.id, nil])
    let table = try #require(evaluation.tableResult(items.id))
    #expect(table.name == "Items" && table.isCalculated && table.calculationFailure == nil)
    #expect(Self.text(source, table.utf8Range) == (try Fold.block(items)))
    #expect(evaluation.tableResult(atLine: table.physicalLines.lowerBound)?.id == items.id)
    #expect(evaluation.tableResult(atLine: results[1].physicalLines.upperBound - 1)?.id == nil)
    #expect(results[1].diagnostics.map(\.code) == [.unsupportedVersion])
    #expect(results[1].value(row: nil, column: items.columns[0].id) == nil)
    #expect(table.columns.map(\.header) == ["Qty", "Amount"])
    let amount = items.columns[1].id
    guard case .value(let twelve)? = table.value(row: items.rows[1], column: amount) else {
      Issue.record("Items!B3 has no value")
      return
    }
    #expect(Fold.describe(twelve) == "12")
    #expect(table.value(row: nil, column: amount) == .text("Amount"))
    #expect(table.address(row: items.rows[1], column: amount) == "Items!B3")
    #expect(table.address(row: nil, column: amount) == "Items!B1")
    #expect(table.nextRecalculation == nil)
    // A clock reader reports when it can change.
    let clock = Fold.table("Clock", headers: ["Day"], rows: [["=today"]])
    let timed = try run.evaluate(try Fold.block(clock))
    #expect(timed.tableResult(clock.id)?.nextRecalculation != nil)
    #expect(timed.nextRecalculation == timed.tableResult(clock.id)?.nextRecalculation)
  }

  @Test func proseFailuresCarryTheOriginalFailingCell() throws {
    // B2 has a syntax error; C2 waits on it; Loop has a cycle.
    let bad = Fold.table(
      "Bad", headers: ["A", "B", "C"], rows: [["1", "=1 +", "=B2 * 2"]])
    let loop = Fold.table("Loop", headers: ["A", "B"], rows: [["=B2", "=A2"]])
    let source =
      (try Fold.block(bad)) + (try Fold.block(loop))
      + "x = Bad!C2\nx + 1\nsum(Bad[B])\nLoop!A2\nBad!A2\n"
    var run = try Fold.Run()
    let evaluation = try run.evaluate(source)
    let lines = SheetSource(source).lines.count
    let prose = Array(evaluation.lines[(lines - 6)..<(lines - 1)])
    func cells(_ line: SheetLineResult) -> [String] {
      line.failureOriginTableCells.map { origin in
        let table = evaluation.tableResult(origin.table)
        return origin.column.flatMap { table?.address(row: origin.row, column: $0) } ?? "table"
      }
    }
    #expect(cells(prose[0]) == ["Bad!B2"])
    #expect(prose[0].failureOriginTableCells.first?.formulaRange != nil)
    // Blocked on line `x`: the cell, carried through the variable.
    #expect(prose[1].failureOriginLineNumbers == [lines - 5])
    #expect(cells(prose[1]) == ["Bad!B2"])
    #expect(cells(prose[2]) == ["Bad!B2"])
    #expect(Set(cells(prose[3])).isSubset(of: ["Loop!A2", "Loop!B2"]) && !cells(prose[3]).isEmpty)
    #expect(prose[4].failureOriginTableCells.isEmpty)
  }

  @Test func anUncalculatedTableIsTheOrigin() throws {
    let heavy = Fold.table(
      "Heavy", headers: ["A", "B"], rows: [["1", "=A2 + 1"], ["2", "=A3 * 3 + 4"]])
    var run = try Fold.Run(
      calculator: SheetCalculator(
        tableOptions: TableCalculationOptions(
          maximumPopulatedCells: 100, maximumScalarOperations: 2)))
    let source = (try Fold.block(heavy)) + "Heavy!A2\n"
    let evaluation = try run.evaluate(source)
    let line = try #require(evaluation.lines.dropLast().last)
    #expect(
      line.failureOriginTableCells
        == [TableCellFailureOrigin(table: heavy.id, row: nil, column: nil, formulaRange: nil)])
    let range = try #require(
      TableSourceDocument.sourceRange(
        of: line.failureOriginTableCells[0], in: SheetSource(source)))
    #expect(Self.text(source, range) == (try Fold.block(heavy)))
  }

  @Test func originsResolveToTheCellRuleOrHeaderSource() throws {
    let table = Fold.table(
      "Items", headers: ["Qty", "Amount"], rows: [["2", "=1 +"], ["oops"]],
      rules: [1: "=[@Qty] * 2"])
    let source = "1\n" + (try Fold.block(table))
    let sheet = SheetSource(source)
    func range(_ row: RowID?, _ column: ColumnID?) throws -> String {
      let origin = TableCellFailureOrigin(
        table: table.id, row: row, column: column, formulaRange: nil)
      return Self.text(source, try #require(TableSourceDocument.sourceRange(of: origin, in: sheet)))
    }
    #expect(try range(table.rows[0], table.columns[1].id) == "\"=1 +\"")
    #expect(try range(table.rows[1], table.columns[1].id) == "\"=[@Qty] * 2\"")
    #expect(try range(table.rows[1], table.columns[0].id) == "\"oops\"")
    #expect(try range(nil, table.columns[1].id) == "\"Amount\"")
    let missing = TableCellFailureOrigin(
      table: Fold.items().id, row: nil, column: nil, formulaRange: nil)
    #expect(TableSourceDocument.sourceRange(of: missing, in: sheet) == nil)
    // A stale block (formula edited without its ledger) still resolves.
    var run = try Fold.Run()
    let evaluation = try run.evaluate(source + "Items!B2\n")
    let origin = try #require(evaluation.lines.dropLast().last?.failureOriginTableCells.first)
    #expect(origin.row == table.rows[0] && origin.column == table.columns[1].id)
  }
}
