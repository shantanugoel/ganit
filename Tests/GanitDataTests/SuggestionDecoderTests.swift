import Foundation
import GanitSuggestionProtocol
import Testing

@Suite
struct SuggestionDecoderTests {
  private let bill = """
    {"schemaVersion":1,"kind":"proposal","candidates":[{
      "id":"C1","edits":[{"target":"T1","replacement":"share = (bill + 10%) / 4"}],
      "bindings":[{"symbol":"bill","source":"S1"}],
      "literals":[{"text":"10%","evidence":"E1"},{"text":"4","evidence":"E2"}],
      "relations":[{"rule":"tip_on_bill","evidence":"E3"},{"rule":"equal_split","evidence":"E4"}],
      "assumptions":[],"summary":"Add the tip, then divide into four equal shares."
    }]}
    """

  @Test func decodesBoundedSourceWithoutAModelAnswer() throws {
    guard case .proposal(let candidates) = try SuggestionDecoder.decode(Data(bill.utf8)) else {
      Issue.record("Expected a source proposal")
      return
    }
    #expect(candidates.count == 1)
    #expect(
      candidates[0].edits == [SuggestionEdit(target: "T1", replacement: "share = (bill + 10%) / 4")]
    )
    #expect(candidates[0].bindings == [SuggestionBinding(symbol: "bill", source: "S1")])
    #expect(candidates[0].literals.count == 2)
    #expect(candidates[0].relations.count == 2)
  }

  @Test(arguments: [
    "{\"schemaVersion\":1,\"kind\":\"value\",\"value\":\"660 INR\"}",
    "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"No\",\"confidence\":99}",
    "{\"schemaVersion\":1,\"kind\":\"proposal\",\"candidates\":[]}",
    "{\"schemaVersion\":1,\"kind\":\"clarify\",\"question\":\"Which?\",\"choices\":[]}",
    "{\"schemaVersion\":1,\"kind\":\"need_context\",\"records\":[\"S1\",\"S1\"],\"reason\":\"Need it\"}",
    "{\"schemaVersion\":true,\"kind\":\"unsupported\",\"reason\":\"No\"}",
    "{\"schemaVersion\":2,\"kind\":\"unsupported\",\"reason\":\"No\"}",
    "{\"schemaVersion\":1,\"kind\":\"clarify\",\"question\":\"Which?\",\"choices\":[1]}",
  ])
  func rejectsInvalidOutcomes(_ source: String) {
    #expect(throws: (any Error).self) { try SuggestionDecoder.decode(Data(source.utf8)) }
  }

  @Test(arguments: ["prefix", "fence", "trailer", "answer", "offset", "literal", "assumption"])
  func rejectsExtraTextAndUnknownNestedFields(_ change: String) {
    let source: String
    switch change {
    case "prefix": source = "Here is a result: " + bill
    case "fence": source = "```json\n" + bill + "\n```"
    case "trailer": source = bill + " 660 INR"
    case "answer":
      source = bill.replacingOccurrences(
        of: "\"summary\":", with: "\"result\":\"660 INR\",\"summary\":")
    case "offset":
      source = bill.replacingOccurrences(of: "\"target\":", with: "\"offset\":0,\"target\":")
    case "literal":
      source = bill.replacingOccurrences(of: "\"text\":\"4\"", with: "\"value\":4,\"text\":\"4\"")
    default:
      source = bill.replacingOccurrences(
        of: "\"assumptions\":[]",
        with:
          "\"assumptions\":[{\"id\":\"A1\",\"text\":\"Estimate\",\"evidence\":\"E1\",\"approved\":true}]"
      )
    }
    #expect(throws: (any Error).self) { try SuggestionDecoder.decode(Data(source.utf8)) }
  }

  @Test func decodesAllNonProposalOutcomes() throws {
    #expect(
      try SuggestionDecoder.decode(
        Data(
          "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"Missing capability\"}".utf8))
        == .unsupported(reason: "Missing capability"))
    #expect(
      try SuggestionDecoder.decode(
        Data(
          "{\"schemaVersion\":1,\"kind\":\"need_context\",\"records\":[\"S2\"],\"reason\":\"Need density\"}"
            .utf8)) == .needContext(records: ["S2"], reason: "Need density"))
    #expect(
      try SuggestionDecoder.decode(
        Data(
          "{\"schemaVersion\":1,\"kind\":\"clarify\",\"question\":\"Density?\",\"choices\":[],\"missingInput\":\"density\"}"
            .utf8))
        == .clarify(
          SuggestionClarification(question: "Density?", choices: [], missingInput: "density")))
  }

  @Test func schemaHasFourStrictVersionedOutcomes() throws {
    let data = try SuggestionSchema.data()
    #expect(data == (try SuggestionSchema.data()))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let alternatives = try #require(root["oneOf"] as? [[String: Any]])
    #expect(alternatives.count == 4)
    for alternative in alternatives {
      #expect(alternative["additionalProperties"] as? Bool == false)
      let properties = try #require(alternative["properties"] as? [String: Any])
      let version = try #require(properties["schemaVersion"] as? [String: Any])
      #expect(version["const"] as? Int == 1)
    }
  }

  @Test(arguments: ["\\n", "\\r", "\\r\\n"])
  func rejectsTooManyPhysicalLines(_ separator: String) {
    let source = bill.replacingOccurrences(
      of: "share = (bill + 10%) / 4",
      with: Array(repeating: "1", count: 17).joined(separator: separator))
    #expect(throws: SuggestionDecodingError.invalidBounds) {
      try SuggestionDecoder.decode(Data(source.utf8))
    }
  }

  @Test func enforcesUTF8AndLineBounds() {
    let replacement = String(repeating: "é", count: 2_049)
    let oversized = bill.replacingOccurrences(of: "share = (bill + 10%) / 4", with: replacement)
    #expect(throws: SuggestionDecodingError.invalidBounds) {
      try SuggestionDecoder.decode(Data(oversized.utf8))
    }
    let multiline = bill.replacingOccurrences(
      of: "share = (bill + 10%) / 4",
      with: Array(repeating: "1", count: 17).joined(separator: "\\n"))
    #expect(throws: SuggestionDecodingError.invalidBounds) {
      try SuggestionDecoder.decode(Data(multiline.utf8))
    }
    #expect(throws: SuggestionDecodingError.payloadTooLarge) {
      try SuggestionDecoder.decode(Data(repeating: 32, count: SuggestionLimits.payloadBytes + 1))
    }
  }
  @Test(arguments: [
    "{\"schemaVersion\":1,\"kind\":\"proposal\",\"kind\":\"unsupported\",\"reason\":\"No\"}",
    "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"No\",}",
    "{\"schemaVersion\":01,\"kind\":\"unsupported\",\"reason\":\"No\"}",
    "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"No\",\"rea\\u0073on\":\"Yes\"}",
    "{\"schemaVersion\":1,\"kind\":\"clarify\",\"question\":\"Which?\",\"choices\":[\"Cost\",]}",
  ])
  func rejectsDuplicateKeysAndNonJSONSyntax(_ source: String) {
    #expect(throws: SuggestionDecodingError.invalidSchema) {
      try SuggestionDecoder.decode(Data(source.utf8))
    }
  }

  @Test func rejectsExcessiveNestingBeforeDecoding() {
    let source = String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)
    #expect(throws: SuggestionDecodingError.invalidBounds) {
      try SuggestionDecoder.decode(Data(source.utf8))
    }
  }

}
