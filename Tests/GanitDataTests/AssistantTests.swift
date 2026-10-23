import Foundation
import Testing

@testable import GanitData

@Suite
struct AssistantTests {
  @Test
  func keepsWhereToAskInPreferences() throws {
    let name = "AssistantTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var settings = AssistantSettings.read(from: defaults)
    #expect(!settings.isEnabled)
    #expect(settings.endpoint == AssistantSettings.defaultEndpoint)
    #expect(settings.effort == .medium)
    #expect(!settings.isReady)

    settings.isEnabled = true
    settings.endpoint = URL(string: "http://localhost:11434/v1/chat/completions")!
    settings.model = "a-local-model"
    settings.effort = .custom("minimal")
    settings.write(to: defaults)

    let read = AssistantSettings.read(from: defaults)
    #expect(read.isEnabled)
    #expect(read.endpoint == settings.endpoint)
    #expect(read.model == "a-local-model")
    #expect(read.effort == .custom("minimal"))
    #expect(read.isReady)
  }
}

/// Effort is one preferences key holding both which level was chosen and,
/// for Custom, what was typed.
@Suite
struct AssistantEffortTests {
  @Test
  func asksAMediumAmountOfThinkingOfAnyoneWhoNeverChose() {
    #expect(AssistantEffort(storage: nil) == .medium)
    #expect(AssistantEffort(storage: "") == .medium)
    #expect(AssistantEffort(storage: "   ") == .medium)
    // A level from a newer Ganit is not a preference this one can honour, and
    // inventing one would be worse than the default.
    #expect(AssistantEffort(storage: "unobtainium") == .medium)
  }

  @Test(
    arguments: zip(AssistantEffort.choices, ["off", "low", "medium", "high", "xhigh", "max"])
  )
  func everyNamedLevelSurvivesAWriteAndARead(effort: AssistantEffort, stored: String) {
    #expect(effort.storageValue == stored)
    #expect(AssistantEffort(storage: stored) == effort)
  }

  @Test(arguments: ["custom:minimal", " custom: minimal ", "custom:   minimal"])
  func aCustomWordSurvivesBeingStoredAndReadBack(stored: String) {
    #expect(AssistantEffort(storage: stored) == .custom("minimal"))
    #expect(AssistantEffort.custom("minimal").storageValue == "custom:minimal")
    #expect(AssistantEffort.custom("minimal").wireValue == "minimal")
  }

  /// A Custom level with nothing in it is Off wearing a different hat, and one
  /// long enough to be a sentence is truncated rather than rejected.
  @Test
  func aCustomLevelWithNothingTypedIsOff() {
    #expect(AssistantEffort(storage: "custom:") == .off)
    #expect(AssistantEffort(storage: "custom:   ") == .off)
    let long = AssistantEffort(storage: "custom:\(String(repeating: "x", count: 200))")
    #expect(long.wireValue?.count == AssistantEffort.maximumCustomLength)
  }

  @Test
  func onlyTheFirstWordOfACustomLevelIsUsed() {
    #expect(AssistantEffort(storage: "custom:think hard please") == .custom("think"))
  }

  @Test
  func customIsTheOnlyLevelThatWantsSomethingTyped() {
    #expect(AssistantEffort.custom("minimal").isCustom)
    for level in AssistantEffort.choices {
      #expect(!level.isCustom)
    }
  }
}

@Suite
struct AssistantEndpointTests {
  @Test func endpointPolicyAllowsHTTPSAndLoopback() {
    for endpoint in [
      "https://api.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:11434/v1",
      "http://[::1]:11434/v1",
    ] {
      #expect(Assistant.isAllowed(URL(string: endpoint)!))
    }
    for endpoint in ["http://example.com/v1", "file:///etc/passwd", "https:///v1"] {
      #expect(!Assistant.isAllowed(URL(string: endpoint)!))
    }
  }

  @Test func endpointPathsUseChatCompletions() {
    for (endpoint, expected) in [
      ("http://localhost:1234", "http://localhost:1234/v1/chat/completions"),
      ("http://localhost:1234/v1/", "http://localhost:1234/v1/chat/completions"),
      ("https://example.com/openai/v1", "https://example.com/openai/v1/chat/completions"),
      ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
    ] {
      #expect(Assistant.chatCompletionsURL(URL(string: endpoint)!).absoluteString == expected)
    }
  }
}
