import Foundation
import Testing

@testable import GanitData

@Suite
struct AssistantTests {
  private func settings(_ port: UInt16, key: String = "a-key") -> AssistantSettings {
    AssistantSettings(
      isEnabled: true,
      endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
      model: "a-model",
      apiKey: key
    )
  }

  private func completion(_ content: String) -> String {
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(content)\"}}]}"
  }

  @Test
  func readsTheAnswerOutOfTheReply() async throws {
    let server = try LoopbackServer(body: completion("10000 ml"), contentType: "application/json")
    defer { server.stop() }

    let answer = try await Assistant(settings: settings(server.port))
      .answer(to: "10 kg of water in ml")

    #expect(answer == "10000 ml")
  }

  /// A model that will not answer, and one that answers with an essay, both
  /// leave the line as Ganit found it.
  @Test(arguments: ["UNKNOWN", "", String(repeating: "word ", count: 40)])
  func hasNoAnswerWhenTheModelGivesNone(reply: String) async throws {
    let server = try LoopbackServer(body: completion(reply), contentType: "application/json")
    defer { server.stop() }

    #expect(try await Assistant(settings: settings(server.port)).answer(to: "a line") == nil)
  }

  @Test
  func refusesAnAddressThatIsNotHTTPSAndIsNotThisMac() async throws {
    let settings = AssistantSettings(
      isEnabled: true, endpoint: URL(string: "http://example.com/v1/chat/completions")!)

    await #expect(throws: AssistantError.disallowedURL) {
      try await Assistant(settings: settings).answer(to: "a line")
    }
    #expect(!settings.isReady)
  }

  @Test
  func acceptsHTTPSAnywhereAndPlainHTTPOnlyOnThisMac() {
    #expect(Assistant.isAllowed(URL(string: "https://api.openai.com/v1")!))
    #expect(Assistant.isAllowed(URL(string: "https://api.openai.com/v1/chat/completions")!))
    #expect(Assistant.isAllowed(URL(string: "http://localhost:11434/v1")!))
    #expect(Assistant.isAllowed(URL(string: "http://127.0.0.1:11434/v1/chat/completions")!))
    #expect(!Assistant.isAllowed(URL(string: "http://example.com/v1")!))
    #expect(!Assistant.isAllowed(URL(string: "file:///etc/passwd")!))
    #expect(!Assistant.isAllowed(URL(string: "https:///v1")!))
  }

  /// Prose is not a question, and is never worth sending.
  @Test
  func neverSendsALineTooLongToBeAQuestion() async throws {
    let server = try LoopbackServer(body: completion("nope"), contentType: "application/json")
    defer { server.stop() }

    let answer = try await Assistant(settings: settings(server.port))
      .answer(to: String(repeating: "x", count: Assistant.maximumLine + 1))

    #expect(answer == nil)
  }

  @Test
  func reportsWhatTheAddressAnsweredWith() async throws {
    let server = try LoopbackServer(body: "not json", contentType: "application/json")
    defer { server.stop() }

    await #expect(throws: AssistantError.malformedPayload) {
      try await Assistant(settings: settings(server.port)).answer(to: "a line")
    }
  }

  /// OpenAI-compatible tools take a `/v1` base. The request still has to
  /// land on `chat/completions`, or llama-swap answers 404.
  @Test
  func postsToChatCompletionsWhenTheAddressIsABase() throws {
    let base = try Assistant(
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "http://127.0.0.1:1234/v1")!, model: "a-model")
    ).request(for: "a line")
    #expect(base.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")

    let trailing = try Assistant(
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "http://127.0.0.1:1234/v1/")!, model: "a-model")
    ).request(for: "a line")
    #expect(trailing.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")

    let host = try Assistant(
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "http://127.0.0.1:1234")!, model: "a-model")
    ).request(for: "a line")
    #expect(host.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")

    let full = try Assistant(settings: settings(1_234, key: "")).request(for: "a line")
    #expect(full.url?.path == "/v1/chat/completions")

    let nested = try Assistant(
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "http://127.0.0.1:1234/openai/v1")!, model: "a-model"
      )
    ).request(for: "a line")
    #expect(nested.url?.absoluteString == "http://127.0.0.1:1234/openai/v1/chat/completions")

    let hostOnly = try Assistant(
      settings: AssistantSettings(
        isEnabled: true, endpoint: URL(string: "http://127.0.0.1:1234/")!, model: "a-model")
    ).request(for: "a line")
    #expect(hostOnly.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
  }

  @Test
  func asksForAJSONValue() throws {
    let request = try Assistant(settings: settings(1_234, key: "")).request(for: "a line")
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("\"response_format\":{\"type\":\"json_object\"}"))
    #expect(body.contains("\"stream\":false"))
  }

  @Test
  func readsAJSONValueOutOfTheReply() async throws {
    let content = try String(
      decoding: JSONEncoder().encode("{\"value\":\"10000 ml\"}"), as: UTF8.self)
    let body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\(content)}}]}"
    let server = try LoopbackServer(body: body, contentType: "application/json")
    defer { server.stop() }

    let answer = try await Assistant(settings: settings(server.port))
      .answer(to: "10 kg of water in ml")

    #expect(answer == "10000 ml")
  }

  @Test
  func readsTheValueFromReasoningWhenContentIsEmpty() async throws {
    let body =
      "{\"choices\":[{\"message\":{\"content\":\"\",\"reasoning_content\":\"10000 ml\"}}]}"
    let server = try LoopbackServer(body: body, contentType: "application/json")
    defer { server.stop() }

    #expect(
      try await Assistant(settings: settings(server.port)).answer(to: "a line") == "10000 ml")
  }

  @Test
  func aBaseAddressReachesChatCompletionsOnTheWire() async throws {
    let server = try LoopbackServer(body: completion("10000 ml"), contentType: "application/json")
    defer { server.stop() }
    let settings = AssistantSettings(
      isEnabled: true,
      endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
      model: "a-model",
      apiKey: "a-key"
    )

    _ = try await Assistant(settings: settings).answer(to: "10 kg of water in ml")
    let raw = try #require(await server.request())
    #expect(raw.hasPrefix("POST /v1/chat/completions HTTP/1.1"))
  }

  /// A model running on this Mac usually wants no key, and asking without one
  /// must not send an empty header.
  @Test
  func sendsNoAuthorizationWithoutAKey() throws {
    let request = try Assistant(settings: settings(1_234, key: "")).request(for: "a line")

    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.httpMethod == "POST")
  }

  /// Preferences hold where to ask. The key is in the keychain, which this
  /// leaves alone.
  @Test
  func keepsWhereToAskInPreferences() throws {
    let name = "AssistantTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var settings = AssistantSettings.read(from: defaults)
    #expect(!settings.isEnabled)
    #expect(settings.endpoint == AssistantSettings.defaultEndpoint)
    #expect(!settings.isReady)

    settings.isEnabled = true
    settings.endpoint = URL(string: "http://localhost:11434/v1/chat/completions")!
    settings.model = "a-local-model"
    settings.write(to: defaults)

    let read = AssistantSettings.read(from: defaults)
    #expect(read.isEnabled)
    #expect(read.endpoint == settings.endpoint)
    #expect(read.model == "a-local-model")
    #expect(read.isReady)
  }
}

@Suite
struct AssistantReplyTests {
  @Test
  func takesTheValueFromJSON() {
    #expect(AssistantReply.value(content: "{\"value\":\"10000 ml\"}") == "10000 ml")
    #expect(AssistantReply.value(content: "{\"answer\":\"32 C\"}") == "32 C")
    #expect(AssistantReply.value(content: "{\"result\":\"3.14\"}") == "3.14")
  }

  @Test
  func dropsMultilineThinkTagsAroundJSON() {
    let reply = """
      <think>
      water is 1 g/ml so 10 kg is 10000 ml
      </think>
      {"value":"10000 ml"}
      """
    #expect(AssistantReply.value(content: reply) == "10000 ml")
  }

  @Test
  func takesTheValueAfterAnOrphanCloseTag() {
    #expect(AssistantReply.value(content: "working\n</think>\n10000 ml") == "10000 ml")
  }

  @Test
  func takesJSONFromAFence() {
    #expect(
      AssistantReply.value(content: "```json\n{\"answer\":\"10000 ml\"}\n```") == "10000 ml")
  }

  @Test
  func dropsAnAnswerPrefixAndTakesTheLastLine() {
    #expect(AssistantReply.value(content: "The conversion is\nAnswer: 10000 ml") == "10000 ml")
  }

  @Test
  func usesReasoningWhenContentIsEmpty() {
    #expect(AssistantReply.value(content: "", reasoning: "10000 ml") == "10000 ml")
  }

  @Test
  func hasNoAnswerForUNKNOWNOrAnEssay() {
    #expect(AssistantReply.value(content: "{\"value\":\"UNKNOWN\"}") == nil)
    #expect(AssistantReply.value(content: String(repeating: "word ", count: 40)) == nil)
  }
}
