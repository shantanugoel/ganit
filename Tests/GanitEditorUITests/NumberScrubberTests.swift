import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

@Suite
struct NumberScrubberTests {
  @Test
  func findsTheNumberWrittenUnderAnOffset() throws {
    let line = "rent = 2,100 + 75.50"
    let rent = try #require(number(in: line, at: 8))
    #expect(rent.text == "2,100")
    #expect(rent.range == NSRange(location: 7, length: 5))
    #expect(rent.scale == 0)

    let tax = try #require(number(in: line, at: 15))
    #expect(tax.text == "75.50")
    #expect(tax.scale == 2)

    // The offset just past a number still names it, so a click at its edge
    // scrubs it.
    #expect(number(in: line, at: 12)?.text == "2,100")
    #expect(number(in: line, at: 0) == nil)
    #expect(number(in: line, at: 6) == nil)
  }

  /// Emoji are more than one UTF-16 code unit, and a text view counts in those.
  @Test
  func countsInTheUnitsATextViewCounts() throws {
    let line = "🏠 rent 2,100"
    let found = try #require(number(in: line, at: 11))
    #expect((line as NSString).substring(with: found.range) == "2,100")
  }

  /// Powers of ten and other radixes say something about how a number is
  /// written that stepping would have to guess at.
  @Test
  func leavesNumbersItWouldHaveToGuessAbout() {
    #expect(number(in: "1.2e6", at: 1) == nil)
    #expect(number(in: "0xff", at: 3) == nil)
    #expect(number(in: "0b1010", at: 3) == nil)
  }

  @Test
  func stepsOneUnitOfTheLastPlaceItWasWrittenWith() throws {
    let cases: [(String, Int, Int?, String?)] = [
      ("2,100", 1, nil, "2,101"),
      ("2,100", -1, nil, "2,099"),
      ("999", 1, nil, "1,000"),
      ("0.50", 1, nil, "0.51"),
      ("0.50", -1, nil, "0.49"),
      // Shift steps ten of the last place; Command a tenth of it.
      ("0.50", 1, 1, "0.60"),
      ("0.50", 1, 3, "0.501"),
      ("2,100", 1, -1, "2,110"),
      ("2,100", 1, 1, "2,100.1"),
      // Digits stop at zero, because the sign in front of a number belongs to
      // the expression rather than to the literal.
      ("3", -8, nil, "0"),
    ]

    for (written, steps, scale, expected) in cases {
      let found = try #require(number(in: written, at: 0))
      let stepped = found.stepped(
        by: steps,
        scale: scale ?? found.scale,
        configuration: .englishUnitedStates
      )
      #expect(stepped == expected, "\(written) by \(steps) at \(scale ?? found.scale)")
    }
  }

  /// A number written without separators keeps being written without them.
  @Test
  func writesTheNumberTheWayItWasFound() throws {
    let ungrouped = try #require(number(in: "1000", at: 0))
    #expect(ungrouped.stepped(by: 1, scale: 0, configuration: .englishUnitedStates) == "1001")
    let grouped = try #require(number(in: "1,000", at: 0))
    #expect(grouped.stepped(by: 1, scale: 0, configuration: .englishUnitedStates) == "1,001")
  }

  /// German writes `1.234,5`, so the digits step and separate its way.
  @Test
  func followsTheGrammarThatReadsTheSheet() throws {
    let german = LexingConfiguration(decimalSeparator: ",", groupingSeparator: ".")
    let found = try #require(
      ScrubbableNumber(in: "1.234,5", at: 0, configuration: german)
    )
    #expect(found.text == "1.234,5")
    #expect(found.stepped(by: 1, scale: 1, configuration: german) == "1.234,6")
  }

  @Test
  func refusesDigitsWiderThanStepping() throws {
    let wide = try #require(number(in: String(repeating: "9", count: 40), at: 0))
    #expect(wide.stepped(by: 1, scale: 0, configuration: .englishUnitedStates) == nil)
  }

  private func number(in line: String, at offset: Int) -> ScrubbableNumber? {
    ScrubbableNumber(in: line, at: offset, configuration: .englishUnitedStates)
  }
}
