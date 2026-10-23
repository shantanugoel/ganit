import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitData

@Suite
struct SuggestionTransportTests {
  private func settings(_ endpoint: String = "https://example.test/v1", key: String = "")
    -> AssistantSettings
  {
    AssistantSettings(
      isEnabled: true, endpoint: URL(string: endpoint)!, model: "fixture-model", apiKey: key)
  }

  @Test func freezesTheExactContextAndDoesNotAttachOtherData() throws {
    let context = Data("{\"target\":\"Add a 10% tip to bill\",\"symbols\":[\"bill\"]}".utf8)
    let wire = try SuggestionWireRequest(settings: settings(key: "fixture-key"), context: context)
    let root = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
    let messages = try #require(root["messages"] as? [[String: String]])
    #expect(messages.count == 2)
    #expect(messages[1]["content"] == String(decoding: context, as: UTF8.self))
    #expect(root["stream"] as? Bool == false)
    #expect(wire.urlRequest.httpBody == wire.body)
    #expect(wire.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    #expect(!String(decoding: wire.body, as: UTF8.self).contains("fixture-key"))
    #expect(wire.endpoint.absoluteString == "https://example.test/v1/chat/completions")
    #expect(wire.timeout == 30)
  }

  @Test func localTimeoutAndFormatFallbackAreExplicit() throws {
    let wire = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:1234/v1"), context: Data("{}".utf8), structured: false)
    let root = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
    #expect(root["response_format"] == nil)
    #expect(wire.timeout == 120)
    #expect(wire.urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func rejectsUnpermittedEndpointsAndInvalidContextBeforeSending() {
    #expect(throws: SuggestionTransportError.disallowedURL) {
      try SuggestionWireRequest(
        settings: settings("http://example.test/v1"), context: Data("{}".utf8))
    }
    for context in [
      Data("[]".utf8), Data([0xff]), Data("private text".utf8),
      Data(repeating: 32, count: SuggestionLimits.requestBytes + 1),
    ] {
      #expect(throws: SuggestionTransportError.invalidContext) {
        try SuggestionWireRequest(settings: settings(), context: context)
      }
    }
  }

  /// An explanation request must stay the same bytes with the schema widened, so
  /// the privacy checks written for a proposal keep covering it.
  @Test func theExplanationRequestIsAProposalRequestWithTheSchemaWidened() throws {
    let context = Data("{\"target\":\"is this the right way to model a tip\"}".utf8)
    let plain = try SuggestionWireRequest(settings: settings(key: "fixture-key"), context: context)
    let asked = try SuggestionWireRequest(
      settings: settings(key: "fixture-key"), context: context, allowsExplanation: true)
    func messages(_ wire: SuggestionWireRequest) throws -> [[String: String]] {
      let root = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
      #expect(
        Set(root.keys).isSubset(
          of: ["messages", "model", "stream", "response_format", "reasoning_effort"]),
        "\(root.keys.sorted())")
      return try #require(root["messages"] as? [[String: String]])
    }
    let before = try messages(plain)
    let after = try messages(asked)
    // What leaves the Mac is identical: the same frozen context, the same model.
    #expect(before[1] == after[1])
    #expect(before[0]["role"] == "system" && after[0]["role"] == "system")
    let beforeHead = before[0]["content"]!.components(separatedBy: "\nResponse schema:\n").first!
    let afterHead = after[0]["content"]!.components(separatedBy: "\nResponse schema:\n").first!
    #expect(afterHead.hasPrefix(beforeHead))
    let added = afterHead.dropFirst(beforeHead.count)
    #expect(added.contains("The user explicitly requested an explanation"))
    #expect(added.contains("Do not calculate, state a numeric result, or write source"))
    #expect(added.contains("no numeric characters"))
    func kinds(_ content: String) throws -> [String] {
      let schema = String(content.components(separatedBy: "Response schema:\n").last!)
      let root = try #require(
        JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
      return try #require(root["oneOf"] as? [[String: Any]]).compactMap {
        (($0["properties"] as? [String: Any])?["kind"] as? [String: Any])?["const"] as? String
      }
    }
    #expect(!(try kinds(before[0]["content"]!).contains("explanation")))
    #expect(try kinds(after[0]["content"]!).contains("explanation"))
    for wire in [plain, asked] {
      #expect(!String(decoding: wire.body, as: UTF8.self).contains("fixture-key"))
    }
  }

  @Test(arguments: ["reasoning", "extraText", "multipleChoices", "parts"])
  func refusesToExtractProposalsFromUnpermittedContent(_ kind: String) throws {
    let valid = "{\"schemaVersion\":1,\"kind\":\"unsupported\",\"reason\":\"Missing input\"}"
    let choice: [String: Any]
    switch kind {
    case "reasoning": choice = ["message": ["content": "", "reasoning_content": valid]]
    case "extraText": choice = ["message": ["content": "Here is JSON: " + valid]]
    case "parts": choice = ["message": ["content": [["text": valid]]]]
    default: choice = ["message": ["content": valid]]
    }
    let choices = kind == "multipleChoices" ? [choice, choice] : [choice]
    let data = try JSONSerialization.data(withJSONObject: ["choices": choices])
    #expect(throws: (any Error).self) { try ProviderSuggestionTransport.content(from: data) }
  }

  @Test func sendsOneRequestWithOnlyTheInspectedBody() async throws {
    let content =
      "{\"schemaVersion\":1,\"kind\":\"clarify\",\"question\":\"What is the density?\",\"choices\":[],\"missingInput\":\"density\"}"
    let completion = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": content]]]
    ])
    let server = try LoopbackServer(
      body: String(decoding: completion, as: UTF8.self), contentType: "application/json")
    defer { server.stop() }
    let wire = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:\(server.port)/v1"),
      context: Data("{\"target\":\"250 g in ml\"}".utf8))
    let response = try await ProviderSuggestionTransport().send(wire)
    #expect(response == Data(content.utf8))
    let raw = try #require(await server.request())
    #expect(raw.contains(String(decoding: wire.body, as: UTF8.self)))
    #expect(raw.hasPrefix("POST /v1/chat/completions HTTP/1.1"))
    #expect(await server.requestCount() == 1)
    let headers = raw.components(separatedBy: "\r\n").dropFirst().prefix { !$0.isEmpty }
    #expect(headers.contains { $0.lowercased() == "user-agent: ganit" })
    #expect(headers.contains { $0.lowercased() == "accept-language: *" })
    #expect(!headers.contains { $0.lowercased().hasPrefix("cookie:") })
    #expect(!headers.contains { $0.lowercased().hasPrefix("authorization:") })
  }

  @Test func providerFormatRejectionReturnsWithoutHiddenRetry() async throws {
    let server = try LoopbackServer(
      body: "format unsupported", status: 422, contentType: "application/json")
    defer { server.stop() }
    let wire = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:\(server.port)/v1"), context: Data("{}".utf8))
    await #expect(throws: SuggestionTransportError.unexpectedStatus(422)) {
      try await ProviderSuggestionTransport().send(wire)
    }
    #expect(await server.requestCount() == 1)
  }
  @Test func refusesRedirectsAndOversizedProviderBodies() async throws {
    let redirect = try LoopbackServer(
      body: "redirect", status: 302, headers: ["Location": "http://127.0.0.1:1/stolen"])
    defer { redirect.stop() }
    let wire = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:\(redirect.port)/v1", key: "synthetic-key"),
      context: Data("{}".utf8))
    await #expect(throws: SuggestionTransportError.unexpectedStatus(302)) {
      try await ProviderSuggestionTransport().send(wire)
    }
    #expect(await redirect.requestCount() == 1)
    let oversized = try LoopbackServer(
      body: String(repeating: "x", count: SuggestionLimits.payloadBytes + 1))
    defer { oversized.stop() }
    let large = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:\(oversized.port)/v1"), context: Data("{}".utf8))
    await #expect(throws: SuggestionTransportError.payloadTooLarge) {
      try await ProviderSuggestionTransport().send(large)
    }
  }

  @Test func requestEncodingCountsEscapedBodyBytesAndHTTPSLoopbackIsLocal() throws {
    let local = try SuggestionWireRequest(
      settings: settings("https://localhost/v1"), context: Data("{}".utf8))
    #expect(local.timeout == 120)
    let text = String(repeating: "\n", count: 20_000)
    let context = try JSONSerialization.data(withJSONObject: ["target": text])
    #expect(context.count < SuggestionLimits.requestBytes)
    #expect(throws: SuggestionTransportError.requestTooLarge) {
      try SuggestionWireRequest(settings: settings(), context: context)
    }
  }

  @Test func rejectedProviderContentRemainsAvailableForExplicitInspection() async throws {
    let raw = "Here is the result: 42."
    let completion = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": raw]]]
    ])
    #expect(throws: SuggestionTransportError.rejectedReply(Data(raw.utf8))) {
      try ProviderSuggestionTransport.content(from: completion)
    }
    let server = try LoopbackServer(
      body: String(decoding: completion, as: UTF8.self), contentType: "application/json")
    defer { server.stop() }
    let wire = try SuggestionWireRequest(
      settings: settings("http://127.0.0.1:\(server.port)/v1"), context: Data("{}".utf8))
    await #expect(throws: SuggestionTransportError.rejectedReply(Data(raw.utf8))) {
      try await ProviderSuggestionTransport().send(wire)
    }
    #expect(await server.requestCount() == 1)
  }

  /// A reply whose words carry a number is rejected by policy, and a repair
  /// prompt repeats the same schema - so the transport must not quietly file it
  /// under "malformed reply" and send the job into a doomed repair loop.
  @Test func wordsThatCarryANumberReachTheJobInsteadOfTheRepairLoop() throws {
    for kind in ["answer", "explanation"] {
      let raw = "{\"schemaVersion\":1,\"kind\":\"\(kind)\",\"text\":\"about 42\"}"
      let completion = try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": raw]]]
      ])
      #expect(throws: SuggestionDecodingError.numericProse) {
        try ProviderSuggestionTransport.content(from: completion)
      }
    }
  }

  @Test func rejectionDetailsDoNotExtractReasoningOrContentParts() throws {
    let raw = "The private reasoning must not supply a source proposal."
    let reasoning = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": "", "reasoning_content": raw]]]
    ])
    #expect(throws: SuggestionTransportError.rejectedReply(Data())) {
      try ProviderSuggestionTransport.content(from: reasoning)
    }
    let parts = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": [["text": raw]]]]]
    ])
    #expect(throws: SuggestionTransportError.malformedCompletion) {
      try ProviderSuggestionTransport.content(from: parts)
    }
  }

}
