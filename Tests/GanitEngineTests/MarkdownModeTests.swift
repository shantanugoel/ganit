import Foundation
import Testing

@testable import GanitEngine

@Suite
struct MarkdownModeTests {
  @Test
  func paragraphsAreNotErrorsAndTrailingMathStillCalculates() throws {
    var calculator = SheetCalculator()
    let source = SheetSource(
      """
      # Saturday baking
      Three cakes, each taking flour and milk.
      Flour for all three: 500 g * 3
      The cost is 100 + 50
      Hello world
      2 + 2 =>
      savings / salary as a share
      Rent - the big one - is due
      Wow!
      """
    )
    let results = try calculator.evaluate(
      source, context: try sheetContext(isMarkdownMode: true)
    ).lines

    if case .heading = results[0].syntax {
    } else {
      Issue.record("Expected a heading")
    }
    #expect(results[0].result == nil)
    guard case .markdown = results[1].syntax else {
      Issue.record("Expected a markdown paragraph")
      return
    }
    #expect(results[1].result == nil)
    guard case .value(.quantity) = results[2].result else {
      Issue.record("Expected a quantity for the labelled line")
      return
    }
    guard case .value(.number(let cost)) = results[3].result else {
      Issue.record("Expected 150 for the sentence with a calculation")
      return
    }
    #expect(cost == .integer(IntegerValue(150)))
    #expect(results[4].result == nil)
    guard case .value(.number(let sum)) = results[5].result else {
      Issue.record("Expected 4 after =>")
      return
    }
    #expect(sum == .integer(IntegerValue(4)))
    // A spaced operator keeps a failing line a calculation, so it says why.
    switch results[6].result {
    case .syntaxFailure, .evaluationFailure:
      break
    default:
      Issue.record("Expected the mistyped calculation to report its problem")
    }
    #expect(results[7].result == nil)
    // A word with an exclamation mark is prose, not a factorial.
    #expect(results[8].result == nil)
  }

  @Test
  func listItemsAndQuotesCalculateTheirWords() throws {
    var calculator = SheetCalculator()
    let source = SheetSource(
      "- 2 + 3 =>\n* Flour 500 g * 3\n12. 10 - 4\n> 7 * 2\n1.5 + 1\n- a list item")
    let results = try calculator.evaluate(
      source, context: try sheetContext(isMarkdownMode: true)
    ).lines
    let numbers = results.map { line -> String? in
      guard case .value(let value) = line.result else {
        return nil
      }
      return "\(value)"
    }
    #expect(numbers[0]?.contains("5") == true)
    guard case .value(.quantity) = results[1].result else {
      Issue.record("Expected a quantity for the starred item")
      return
    }
    #expect(numbers[2]?.contains("6") == true)
    #expect(numbers[3]?.contains("14") == true)
    #expect(numbers[4] != nil)
    #expect(results[5].result == nil)
  }

  @Test
  func ordinarySheetsStillReportUnknownWords() throws {
    #expect(try sheetOutcomes("Hello world")[0] == "syntax.unexpectedToken")
  }
}
