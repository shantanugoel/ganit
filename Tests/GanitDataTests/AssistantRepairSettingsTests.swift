import Foundation
import Testing

@testable import GanitData

@Suite
struct AssistantRepairSettingsTests {
  @Test func newAndExistingPreferencesUseTwoRepairAttempts() throws {
    #expect(AssistantSettings().repairAttempts == 2)
    let name = "AssistantRepairSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("low", forKey: "AssistantEffort")
    #expect(AssistantSettings.read(from: defaults).repairAttempts == 2)
    defaults.set("invalid", forKey: "AssistantRepairAttempts")
    #expect(AssistantSettings.read(from: defaults).repairAttempts == 2)
  }

  @Test(arguments: [(-1, 0), (0, 0), (1, 1), (2, 2), (3, 3), (4, 3), (Int.min, 0), (Int.max, 3)])
  func initializationMutationAndStorageKeepThePermittedRange(input: Int, expected: Int) throws {
    var settings = AssistantSettings(repairAttempts: input)
    #expect(settings.repairAttempts == expected)
    settings.repairAttempts = input
    #expect(settings.repairAttempts == expected)
    let name = "AssistantRepairSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    settings.write(to: defaults)
    #expect(defaults.integer(forKey: "AssistantRepairAttempts") == expected)
    #expect(AssistantSettings.read(from: defaults).repairAttempts == expected)
    defaults.set(input, forKey: "AssistantRepairAttempts")
    #expect(AssistantSettings.read(from: defaults).repairAttempts == expected)
  }
}
