import Foundation
import Testing

@testable import GanitData

@Suite
struct AssistantProviderTests {
  @Test func presetsUseTheirOwnURLsAndAuthentication() throws {
    let endpoints: [(AssistantProvider, String, String)] = [
      (.openAI, "https://api.openai.com/v1", "models"),
      (.openRouter, "https://openrouter.ai/api/v1", "models/user"),
      (.ollama, "http://localhost:11434/v1", "models"),
      (.lmStudio, "http://localhost:1234/v1", "models"),
    ]
    for (provider, base, suffix) in endpoints {
      let endpoint = try #require(provider.defaultEndpoint)
      #expect(endpoint.absoluteString == base)
      #expect(AssistantSettings(provider: provider).endpoint == endpoint)
      #expect(provider.modelsURL(endpoint).absoluteString == base + "/" + suffix)
      #expect(Assistant.chatCompletionsURL(endpoint).absoluteString == base + "/chat/completions")
      let settings = AssistantSettings(
        provider: provider, isEnabled: true, endpoint: endpoint, apiKey: "fixture-key")
      let wire = try SuggestionWireRequest(settings: settings, context: Data("{}".utf8))
      #expect(wire.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
      if provider.requiresKey {
        #expect(throws: ProviderFailure(status: nil, category: .authentication)) {
          try provider.authorization(apiKey: "")
        }
        var missing = settings
        missing.apiKey = ""
        #expect(!missing.isReady)
      } else {
        #expect(try provider.authorization(apiKey: "") == nil)
        var noKey = settings
        noKey.apiKey = ""
        #expect(
          try SuggestionWireRequest(settings: noKey, context: Data("{}".utf8)).urlRequest.value(
            forHTTPHeaderField: "Authorization") == nil)
      }
    }
    #expect(AssistantProvider.custom.defaultEndpoint == nil)
  }

  @Test func customDiscoveryPreservesPrefixesAndStoredEndpoints() {
    for (input, output) in [
      ("https://host", "https://host/v1/models"),
      ("https://host/", "https://host/v1/models"),
      ("https://host/chat/completions", "https://host/models"),
      ("https://host/prefix/v1", "https://host/prefix/v1/models"),
      ("https://host/prefix/v1/", "https://host/prefix/v1/models"),
      ("https://host/prefix/v1/chat/completions", "https://host/prefix/v1/models"),
      ("https://host/prefix/v1/chat/completions/", "https://host/prefix/v1/models"),
      ("https://host/prefix%20a/v1", "https://host/prefix%20a/v1/models"),
    ] {
      let endpoint = URL(string: input)!
      #expect(AssistantProvider.custom.modelsURL(endpoint).absoluteString == output)
      #expect(endpoint.absoluteString == input)
    }
  }

  @Test func oldPreferencesStayCustomAndKeepEveryValue() throws {
    let name = "AssistantProviderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let legacy = AssistantSettings(
      isEnabled: true, endpoint: URL(string: "https://api.openai.com/prefix/v1")!,
      model: "old-model", effort: .custom("minimal"), repairAttempts: 1, markAIDerivedAnswers: false
    )
    legacy.write(to: defaults)
    defaults.removeObject(forKey: "AssistantProvider")
    #expect(AssistantSettings.read(from: defaults) == legacy)
    var preset = legacy
    preset.provider = .openRouter
    preset.write(to: defaults)
    #expect(AssistantSettings.read(from: defaults) == preset)
    #expect(defaults.string(forKey: "AssistantProvider") == "openRouter")
    #expect(
      !defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "fixture-key" })
  }

  @Test func draftClearsKeysOnlyForProviderOrOriginChanges() {
    let saved = AssistantSettings(
      endpoint: URL(string: "https://EXAMPLE.test/v1")!, apiKey: "saved-key")
    var draft = AssistantConnectionDraft(settings: saved)
    draft.setEndpoint("https://example.test:443/other/v1")
    #expect(draft.apiKey == "saved-key")
    draft.setEndpoint("https://example.test:444/other/v1")
    #expect(draft.apiKey.isEmpty)
    draft.apiKey = "new-key"
    draft.setEndpoint("https://elsewhere.test/v1")
    #expect(draft.apiKey.isEmpty)
    draft.apiKey = "another-key"
    draft.selectProvider(.ollama)
    #expect(draft.apiKey.isEmpty)
    #expect(draft.endpoint == "http://localhost:11434/v1")
    draft.apiKey = "local-key"
    draft.setEndpoint("http://localhost:11434/other")
    #expect(draft.apiKey == "local-key")
    draft.setEndpoint("invalid address")
    #expect(draft.apiKey.isEmpty)
    #expect(saved.apiKey == "saved-key")
  }
}
