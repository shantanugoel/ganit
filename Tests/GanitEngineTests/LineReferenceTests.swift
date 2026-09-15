import Testing

@testable import GanitEngine

@Suite
struct LineReferenceTests {
  @Test
  func resolvesUpwardLineNumbers() throws {
    let results = try sheetOutcomes(
      "10\r\n20\n// note\nline 1 + line 2\nline 5\nline 3\nline 7\n1 m + 1 s\nline 8"
    )

    #expect(results[3] == "30")
    #expect(results[4] == "error.evaluation.invalidReference")
    #expect(results[5] == "error.evaluation.invalidReference")
    #expect(results[6] == "error.evaluation.invalidReference")
    #expect(results[8] == "error.evaluation.unavailableReference")
  }

  @Test
  func previousReadsTheNearestResultInTheBlock() throws {
    let results = try sheetOutcomes("10\nprev * 2\n// note\nprevious + 1\n\nprevious")

    #expect(results[1] == "20")
    #expect(results[3] == "21")
    #expect(results[5] == "error.evaluation.invalidReference")
  }

  @Test
  func aggregatesTheCurrentBlock() throws {
    let results = try sheetOutcomes(
      """
      1
      2
      Rent: rent = 3
      4
      sum
      total
      average
      median
      count
      """
    )

    #expect(results[4] == "10")
    #expect(results[5] == "10")
    #expect(results[6] == "5/2")
    #expect(results[7] == "5/2")
    #expect(results[8] == "4")
    #expect(try sheetOutcomes("3\n1\n2\nmedian").last == "2")
  }

  @Test
  func blankLinesHeadingsAndDividersEndBlocks() throws {
    #expect(try sheetOutcomes("1\n2\n\n3\nsum").last == "3")
    #expect(try sheetOutcomes("1\n# Next\n3\nsum").last == "3")
    #expect(try sheetOutcomes("1\n---\n3\nsum").last == "3")
    #expect(try sheetOutcomes("1\n// note\n3\nsum").last == "4")
  }

  @Test
  func subtotalsStartAfterThePreviousSubtotal() throws {
    let results = try sheetOutcomes("1\n2\nsubtotal\n3\n4\nsubtotal * 1\ntotal\ncount")

    #expect(results[2] == "3")
    #expect(results[5] == "7")
    #expect(results[6] == "10")
    #expect(results[7] == "4")
  }

  @Test
  func emptyAndInvalidAggregatesAreExplicit() throws {
    let results = try sheetOutcomes("sum\ncount\naverage\nmedian")
    #expect(results[0] == "0")
    #expect(results[1] == "0")
    #expect(try sheetOutcomes("average").last == "error.evaluation.invalidReference")
    #expect(try sheetOutcomes("median").last == "error.evaluation.invalidReference")
    #expect(
      try sheetOutcomes("1\n1 m + 1 s\nsum").last
        == "error.evaluation.unavailableReference"
    )
    #expect(try sheetOutcomes("1\n2 m\nsum").last == "error.evaluation.typeMismatch")
    #expect(try sheetOutcomes("1\n2 +\ncount").last == "error.evaluation.unavailableReference")
  }

  @Test
  func aggregatesQuantitiesDimensionally() throws {
    let sheet = SheetSource("1 km\n500 m\nsum\n\n1 km\n10 m\n2 m\nmedian")
    let results = CalculationEngine().evaluate(sheet, context: try sheetContext())

    guard case .value(.quantity(let sum)) = results[2].result,
      case .value(.quantity(let median)) = results[7].result
    else {
      Issue.record("Expected quantity aggregates")
      return
    }
    #expect(sum.unit.symbol == "km")
    #expect(
      sum.magnitude
        == .rational(try RationalValue(numerator: IntegerValue(3), denominator: IntegerValue(2))))
    #expect(median.unit.symbol == "m")
    #expect(median.magnitude == .integer(IntegerValue(10)))
  }

  @Test
  func referenceKeywordsCannotNameVariablesAlone() throws {
    let results = try sheetOutcomes("total = 5\nline = 2\ntotal rent = 7\ntotal rent\nprev")

    #expect(results[0] == "syntax.invalidVariableName")
    #expect(results[1] == "syntax.invalidVariableName")
    #expect(results[3] == "7")
    #expect(results[4] == "7")
  }
}
