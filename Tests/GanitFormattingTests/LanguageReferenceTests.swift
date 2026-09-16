import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct LanguageReferenceTests {
  @Test
  func coversEveryBuiltInAndFinanceFunction() {
    for function in BuiltInFunction.allCases {
      #expect(
        LanguageReference.topic(named: function.rawValue) != nil,
        "\(function.rawValue)")
    }
    for function in FinanceFunction.allCases {
      #expect(
        LanguageReference.topic(named: function.rawValue) != nil,
        "\(function.rawValue)")
    }
  }

  @Test
  func searchFindsGrammarFunctionsAndKeywords() {
    #expect(LanguageReference.topics(matching: "sqrt").contains { $0.title == "sqrt" })
    #expect(
      LanguageReference.topics(matching: "percentage").contains { $0.id == "grammar.percentages" })
    #expect(LanguageReference.topics(matching: "subtotal").contains { $0.title == "subtotal" })
    #expect(LanguageReference.topics(matching: "fv amount").contains { $0.title == "fv" })
    #expect(LanguageReference.topics(matching: "no-such-topic").isEmpty)
    #expect(LanguageReference.topic(named: "pi")?.id == "grammar.constants")
  }

  @Test
  func emptySearchReturnsEveryTopic() {
    #expect(LanguageReference.topics(matching: "").count == LanguageReference.topics.count)
    #expect(LanguageReference.topics(matching: "   ").count == LanguageReference.topics.count)
  }
}
