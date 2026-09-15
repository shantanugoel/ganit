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
    #expect(Assistant.isAllowed(URL(string: "https://api.openai.com/v1/chat/completions")!))
    #expect(Assistant.isAllowed(URL(string: "http://localhost:11434/v1/chat/completions")!))
    #expect(Assistant.isAllowed(URL(string: "http://127.0.0.1:11434/v1/chat/completions")!))
    #expect(!Assistant.isAllowed(URL(string: "http://example.com/v1/chat/completions")!))
    #expect(!Assistant.isAllowed(URL(string: "file:///etc/passwd")!))
    #expect(!Assistant.isAllowed(URL(string: "https:///v1/chat/completions")!))
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
