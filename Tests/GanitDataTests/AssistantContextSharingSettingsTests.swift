import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitData

@Suite
struct AssistantContextSharingSettingsTests {
  @Test func nobodyWhoNeverOpenedSettingsSharesMoreThanNeeded() throws {
    #expect(AssistantSettings().contextSharing == .needed)
    let name = "AssistantContextSharingSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(AssistantSettings.read(from: defaults).contextSharing == .needed)
    defaults.set("everything", forKey: "AssistantContextSharing")
    #expect(AssistantSettings.read(from: defaults).contextSharing == .needed)
  }

  @Test(arguments: AssistantContextSharing.allCases)
  func eachLevelIsReadBackAsSaved(level: AssistantContextSharing) throws {
    let name = "AssistantContextSharingSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    AssistantSettings(contextSharing: level).write(to: defaults)
    #expect(defaults.string(forKey: "AssistantContextSharing") == level.rawValue)
    #expect(AssistantSettings.read(from: defaults).contextSharing == level)
  }

  private func system(_ context: [String: Any]) throws -> String {
    let request = try SuggestionWireRequest(
      settings: AssistantSettings(isEnabled: true, model: "fixture"),
      context: JSONSerialization.data(withJSONObject: context))
    let body = try #require(
      JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    return try #require(messages.first?["content"] as? String)
  }

  @Test func onlyAContextWithTheIndexOrSheetSaysHowToReadThem() throws {
    let plain = try system(["target": ["handle": "T1", "source": "x"]])
    #expect(!plain.contains("The index lists"))
    #expect(!plain.contains("The sheet field"))
    let names = try system(["target": ["handle": "T1", "source": "x"], "index": []])
    #expect(names.contains("The index lists"))
    #expect(!names.contains("The sheet field"))
    let sheet = try system(["target": ["handle": "T1", "source": "x"], "sheet": "x"])
    #expect(sheet.contains("The sheet field"))
    #expect(names.hasPrefix(String(plain.prefix(200))))
  }
}
