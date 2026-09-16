import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct LanguageCompletionsTests {
  @Test
  func offersFunctionsKeywordsAndConstants() {
    #expect(LanguageCompletions.items.contains("sqrt("))
    #expect(LanguageCompletions.items.contains("pmt("))
    #expect(LanguageCompletions.items.contains("subtotal"))
    #expect(LanguageCompletions.items.contains("pi"))
  }

  @Test
  func matchingIsAPrefix() {
    #expect(LanguageCompletions.matching("sq") == ["sqrt("])
    #expect(LanguageCompletions.matching("log").contains("log("))
    #expect(LanguageCompletions.matching("log").contains("log10("))
    #expect(LanguageCompletions.matching("nope").isEmpty)
    #expect(LanguageCompletions.matching("").isEmpty)
  }
}
