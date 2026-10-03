import Foundation
import GanitFormatting
import Testing

@testable import GanitEngine

/// M6 task 1: a table exports as TSV or CSV, with locale separators, header
/// handling, and the safe spreadsheet treatment of fields another app would
/// run as formulas.
@Suite struct TableGridTextTests {
  /// A calculated table: Qty literals, an Amount rule, and a sum total.
  static func itemsSnapshot() throws -> TableResultSnapshot {
    var table = TableModel.creating(
      name: "Items", headers: [("Qty", .value), ("Amount", .value)], rowCount: 2)
    table.columns[1].rule = "=[@Qty] * 3"
    table.columns[1].total = .sum
    for (row, source) in ["2", "4"].enumerated() {
      table.cells.append(
        TableCell(
          row: table.rows[row], column: table.columns[0].id, source: source, isOverride: false))
    }
    var calculator = SheetCalculator()
    return try #require(
      calculator.evaluate(
        SheetSource(try TableSourceDocument.canonicalBlock(for: table)),
        context: try sheetContext()
      ).tableResult(table.id))
  }

  static func sheetContext() throws -> EvaluationContext {
    try EvaluationContext(
      localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates, angleMode: .radians,
      precision: PrecisionContext(significantDecimalDigits: 15),
      now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
      timeZone: #require(TimeZone(identifier: "UTC")))
  }

  static func grid(
    _ rows: [[String]], headers: [String] = ["A"], totals: [String?] = [],
    failures: [String] = []
  ) -> TableGrid {
    TableGrid(
      name: "T", headers: headers, rows: rows, totals: totals, failures: failures)
  }

  @Test func valuesGridMatchesDisplayTextAndTotals() throws {
    let snapshot = try Self.itemsSnapshot()
    let context = try Self.sheetContext()
    let grid = TableGridText.grid(
      snapshot, formatter: ResultFormatter(context: context),
      diagnostics: DiagnosticFormatter(context: context))
    #expect(grid.name == "Items")
    #expect(grid.headers == ["Qty", "Amount"])
    #expect(grid.rows == [["2", "6"], ["4", "12"]])
    #expect(grid.totals == [nil, "18"])
    #expect(grid.failures.isEmpty)
  }

  @Test func tsvGuardsFormulaFieldsAndKeepsNumbers() {
    let grid = Self.grid(
      [["2", "=[@Qty] * 3"], ["4", "9"]],
      headers: ["Qty", "Amount"])
    #expect(
      TableGridText.text(grid, format: .tsv, locale: Locale(identifier: "en_US"))
        == "Qty\tAmount\n2\t'=[@Qty] * 3\n4\t9\n")
  }

  @Test func csvQuotesSeparatorAwareFields() {
    let grid = Self.grid(
      [["soft, \"extra\"", "-5"]],
      headers: ["Note", "Cost,USD"])
    #expect(
      TableGridText.text(grid, format: .csv, locale: Locale(identifier: "en_US"))
        == "Note,\"Cost,USD\"\r\n\"soft, \"\"extra\"\"\",-5\r\n")
  }

  @Test func decimalCommaLocaleUsesSemicolonSeparator() {
    let grid = Self.grid([["1,5"], ["=x"]], headers: ["A"])
    #expect(
      TableGridText.text(grid, format: .csv, locale: Locale(identifier: "de_DE"))
        == "A\r\n1,5\r\n'=x\r\n")
  }

  @Test func headersCanBeLeftOut() {
    let grid = Self.grid([["1", "2"]], headers: ["A", "B"])
    #expect(
      TableGridText.text(
        grid, format: .tsv, includesHeader: false, locale: Locale(identifier: "en_US"))
        == "1\t2\n")
  }

  @Test func failuresComeBeforeTheGrid() {
    let grid = Self.grid([], headers: [], failures: ["This table block is not valid."])
    #expect(
      TableGridText.text(grid, format: .csv, locale: Locale(identifier: "en_US"))
        == "This table block is not valid.\r\n")
  }

  @Test func totalsRowFollowsTheData() {
    let grid = Self.grid([["1", ""], ["2", ""]], headers: ["A", "B"], totals: [nil, "3"])
    #expect(
      TableGridText.text(grid, format: .tsv, locale: Locale(identifier: "en_US"))
        == "A\tB\n1\t\n2\t\n\t3\n")
  }

  @Test func negativeNumbersStayUnguarded() {
    let grid = Self.grid([["-5"], ["@name"]])
    #expect(
      TableGridText.text(grid, format: .tsv, locale: Locale(identifier: "en_US"))
        == "A\n-5\n'@name\n")
  }
}
