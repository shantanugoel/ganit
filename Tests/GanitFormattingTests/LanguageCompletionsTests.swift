import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct LanguageCompletionsTests {
  @Test
  func offersFunctionsKeywordsAndConstants() {
    #expect(LanguageCompletions.items.contains("sqrt(x)"))
    #expect(LanguageCompletions.items.contains("pmt(amount, rate, periods)"))
    #expect(LanguageCompletions.items.contains("subtotal"))
    #expect(LanguageCompletions.items.contains("pi"))
  }

  @Test
  func matchingIsAPrefix() {
    #expect(LanguageCompletions.matching("sq") == ["sqrt(x)"])
    #expect(LanguageCompletions.matching("log").contains("log(x)"))
    #expect(LanguageCompletions.matching("log").contains("log10(x)"))
    #expect(LanguageCompletions.matching("nope").isEmpty)
    #expect(LanguageCompletions.matching("").isEmpty)
  }

  @Test
  func argumentRangesFollowTheSignature() {
    let ranges = LanguageCompletions.argumentRanges(in: "round(x, places)", at: 3)
    #expect(ranges.map(\.location) == [3 + 6, 3 + 9])
    #expect(ranges.map(\.length) == [1, 6])
  }
}
