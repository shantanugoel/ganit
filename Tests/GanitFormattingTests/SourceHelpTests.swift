import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct SourceHelpTests {
  @Test
  func hoveringAFunctionNamesItsSignature() {
    let help = SourceHelpLookup.at(utf16Offset: 1, in: "sqrt(2)", diagnostic: nil)
    #expect(help?.topicID == "function.sqrt")
    #expect(help?.tooltip.contains("sqrt(x)") == true)
    #expect(help?.menuTitle.contains("sqrt(x)") == true)
  }

  @Test
  func hoveringAnErrorShowsTheMessage() {
    let diagnostic = FormattedDiagnostic(
      code: "evaluation.divisionByZero",
      severity: .error,
      ranges: [
        SourceRange(lowerBound: 2, upperBound: 3, graphemeLowerBound: 2, graphemeUpperBound: 3)
      ],
      message: "Cannot divide by zero."
    )
    let help = SourceHelpLookup.at(utf16Offset: 2, in: "1/0", diagnostic: diagnostic)
    #expect(help?.topicID == nil)
    #expect(help?.tooltip == "Cannot divide by zero.")
    #expect(
      SourceHelpLookup.at(utf16Offset: 3, in: "1/0", diagnostic: diagnostic)?.tooltip
        == "Cannot divide by zero.")
  }

  @Test
  func hoveringAKeywordFindsItsTopic() {
    #expect(
      SourceHelpLookup.at(utf16Offset: 0, in: "subtotal", diagnostic: nil)?.topicID
        == "keyword.subtotal")
    #expect(
      SourceHelpLookup.at(utf16Offset: 0, in: "pi", diagnostic: nil)?.topicID == "grammar.constants"
    )
  }

  @Test
  func ignoresOrdinaryNumbers() {
    #expect(SourceHelpLookup.at(utf16Offset: 0, in: "12", diagnostic: nil) == nil)
  }
}
