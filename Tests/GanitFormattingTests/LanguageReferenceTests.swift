import Foundation
import GanitEngine
import Testing

@testable import GanitFormatting

@Suite
struct LanguageReferenceTests {
  @Test
  func everydayWordsFindTheTopicThatAnswersThem() {
    #expect(LanguageReference.topics(matching: "mortgage").contains { $0.title == "pmt" })
    #expect(LanguageReference.topics(matching: "EMI").contains { $0.title == "pmt" })
    #expect(LanguageReference.topics(matching: "compound interest").contains { $0.title == "fv" })
    #expect(LanguageReference.topics(matching: "GST").contains { $0.id == "grammar.percentages" })
    // The Units topic lists the units themselves, so a search for one finds it.
    let units = LanguageReference.topic(id: "grammar.units")
    #expect(units?.body.contains("Wh") == true)
    #expect(LanguageReference.topics(matching: "knot").contains { $0.id == "grammar.units" })
    #expect(LanguageReference.unitSymbols.contains("Ω"))
  }

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
    #expect(LanguageReference.topic(named: "ask_assistant") == nil)
    #expect(LanguageReference.topics(matching: "ask_assistant").isEmpty)
    let ask = LanguageReference.topic(id: "grammar.ask")
    #expect(ask?.body.contains("Opening Ask or Context sends nothing") == true)
    #expect(ask?.body.contains("Ganit asks when only you know") == true)
    #expect(LanguageReference.topics(matching: "context").contains { $0.id == "grammar.ask" })
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
