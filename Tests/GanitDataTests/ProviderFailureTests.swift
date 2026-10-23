import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitData

@Suite
struct ProviderFailureTests {
  private func failure(_ fields: [String: Any], status: Int = 400) throws -> ProviderFailure {
    let data = try JSONSerialization.data(withJSONObject: ["error": fields])
    return try #require(ProviderFailure.decode(data, status: status))
  }

  @Test func optionalFieldsFallBackSeparatelyAndOnlyWhenPresent() throws {
    for field in ["response_format", "reasoning_effort"] {
      let error = try failure([
        "code": "unsupported_parameter", "param": field, "message": "secret",
      ])
      #expect(error.category == .parameter)
      #expect(error.parameter == field)
      #expect(error.code == "unsupported_parameter")
      let next = try #require(error.fallback(structured: true, effort: true))
      #expect(next.structured == (field != "response_format"))
      #expect(next.effort == (field != "reasoning_effort"))
      #expect(error.fallback(structured: next.structured, effort: next.effort) == nil)
      #expect(!String(describing: error).contains("secret"))
      let messageOnly = try failure(["message": "Unsupported parameter: '\(field)'."], status: 422)
      #expect(messageOnly.category == .parameter)
      #expect(messageOnly.fallback(structured: true, effort: true) != nil)
    }
    let unrelated = try failure(["message": "Unsupported parameter: temperature"])
    #expect(unrelated.parameter == "temperature")
    #expect(unrelated.fallback(structured: true, effort: true) == nil)
    let missingModel = try failure(["message": "Missing required parameter: model"])
    #expect(missingModel.category == .model)
    #expect(missingModel.fallback(structured: true, effort: true) == nil)
    let unknown = try failure(["code": "new_code", "message": "No details"], status: 422)
    let next = try #require(unknown.fallback(structured: true, effort: true))
    #expect(!next.structured && !next.effort)
    #expect(unknown.fallback(structured: false, effort: false) == nil)
    #expect(
      try failure(["param": "temperature", "message": "invalid"]).fallback(
        structured: true, effort: true) == nil)
  }

  @Test func recognizedFailuresNeverDropOptionalFields() throws {
    for (code, category) in [
      ("context_length_exceeded", ProviderErrorCategory.contextLimit),
      ("model_not_found", .model), ("invalid_api_key", .authentication),
      ("rate_limit_exceeded", .rateLimit), ("server_error", .server),
      ("content_policy_violation", .request),
    ] {
      for includeParameter in [false, true] {
        var fields = [
          "code": code, "type": "invalid_request_error", "message": "Unsupported response_format",
        ]
        if includeParameter { fields["param"] = "response_format" }
        let error = try failure(fields)
        #expect(error.category == category)
        #expect(error.fallback(structured: true, effort: true) == nil)
      }
    }
    for status in [401, 403, 404, 429, 500, 503] {
      #expect(
        try failure(["param": "response_format", "code": "unsupported_parameter"], status: status)
          .fallback(structured: true, effort: true) == nil)
    }
  }

  @Test func successfulHTTPStatusCanContainAnErrorOrFailedPartialContent() throws {
    let partial = #"{"schemaVersion":1,"kind":"unsupported","reason":"partial"}"#
    for object: [String: Any] in [
      ["error": ["code": 401, "message": "secret"]],
      ["choices": [["error": ["code": "model_not_found"], "message": ["content": partial]]]],
      ["choices": [["finish_reason": "error", "message": ["content": partial]]]],
    ] {
      let data = try JSONSerialization.data(withJSONObject: object)
      do {
        _ = try ProviderSuggestionTransport.content(from: data)
        Issue.record("Failed partial content must not be accepted")
      } catch SuggestionTransportError.provider(let error) {
        #expect(error.status == 200)
        #expect(error.category != .unknown)
        #expect(error.fallback(structured: true, effort: true) == nil)
      }
    }
  }

  @Test func httpErrorBodyIsBoundedAndStructuredDetailsReachTheCaller() async throws {
    let server = try LoopbackServer(
      body:
        #"{"error":{"code":"unsupported_parameter","param":"reasoning_effort","type":"invalid_request_error","message":"invalid secret"}}"#,
      status: 422)
    defer { server.stop() }
    let settings = AssistantSettings(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1")!)
    let wire = try SuggestionWireRequest(settings: settings, context: Data("{}".utf8))
    do {
      _ = try await ProviderSuggestionTransport().send(wire)
      Issue.record("Expected a parameter error")
    } catch SuggestionTransportError.provider(let error) {
      #expect(error.status == 422)
      #expect(error.category == .parameter)
      #expect(error.type == "invalid_request_error")
      #expect(error.parameter == "reasoning_effort")
    }
    let large = try LoopbackServer(
      body: String(repeating: "x", count: SuggestionLimits.payloadBytes + 1), status: 400)
    defer { large.stop() }
    let rejected = try SuggestionWireRequest(
      settings: AssistantSettings(endpoint: URL(string: "http://127.0.0.1:\(large.port)/v1")!),
      context: Data("{}".utf8))
    await #expect(throws: SuggestionTransportError.payloadTooLarge) {
      try await ProviderSuggestionTransport().send(rejected)
    }
  }
}
