import Foundation
import GanitSuggestionProtocol
import Testing

@Suite
struct ExplanationProtocolTests {
  private func payload(_ text: String, extra: Bool = false) throws -> Data {
    var root: [String: Any] = ["schemaVersion": 1, "kind": "explanation", "text": text]
    if extra { root["answer"] = "value" }
    return try JSONSerialization.data(withJSONObject: root)
  }

  @Test func boundedPlainProseIsAnExplanation() throws {
    let text = "Apply the tip before the split."
    #expect(try SuggestionDecoder.decode(payload(text)) == .explanation(text))
  }

  @Test(arguments: [
    "The result is 920.", "The result is ９２０.", "The result is Ⅳ.", "The result is ½.",
    "bill = amount", "tip + bill", "10%", " ", String(repeating: "a", count: 8193),
  ])
  func numbersEquationsAndUnboundedTextAreRejected(_ text: String) throws {
    #expect(throws: SuggestionDecodingError.self) { try SuggestionDecoder.decode(payload(text)) }
  }

  @Test func unknownFieldsAreRejected() throws {
    #expect(throws: SuggestionDecodingError.self) {
      try SuggestionDecoder.decode(payload("Plain prose.", extra: true))
    }
  }

  @Test func schemaOnlyOffersExplanationsOnExplicitOptIn() throws {
    func kinds(_ data: Data) throws -> [String] {
      let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let branches = try #require(root["oneOf"] as? [[String: Any]])
      return branches.compactMap {
        (($0["properties"] as? [String: Any])?["kind"] as? [String: Any])?["const"] as? String
      }
    }
    #expect(try !kinds(SuggestionSchema.data()).contains("explanation"))
    #expect(try kinds(SuggestionSchema.data(allowsExplanation: true)).contains("explanation"))
  }
}
