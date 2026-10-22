import Foundation
import Testing

@testable import GanitData

struct AssumptionDisplaySettingsTests {
  @Test func marksStartEnabledAndPersistWithoutChangingTheProvider() throws {
    let name = "AssumptionDisplaySettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(AssistantSettings().markAIDerivedAnswers)
    #expect(AssistantSettings.read(from: defaults).markAIDerivedAnswers)
    var settings = AssistantSettings(model: "synthetic", markAIDerivedAnswers: false)
    settings.write(to: defaults)
    #expect(!AssistantSettings.read(from: defaults).markAIDerivedAnswers)
    #expect(AssistantSettings.read(from: defaults).model == "synthetic")
    settings.markAIDerivedAnswers = true
    settings.write(to: defaults)
    #expect(AssistantSettings.read(from: defaults).markAIDerivedAnswers)
  }
}
