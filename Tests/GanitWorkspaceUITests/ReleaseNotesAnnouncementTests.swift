import Foundation
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct ReleaseNotesAnnouncementTests {
  @Test
  func eachInstalledVersionAppearsOnceAndOnlyAfterPresentation() throws {
    let suite = "GanitReleaseNotesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "HasSeenReferencePicker")
    let first = ReleaseNotesAnnouncement(defaults: defaults, version: "0.5.5")
    #expect(first.shouldShow)
    #expect(ReleaseNotesAnnouncement(defaults: defaults, version: "0.5.5").shouldShow)
    first.didShow()
    #expect(!first.shouldShow)
    #expect(!ReleaseNotesAnnouncement(defaults: defaults, version: "0.5.5").shouldShow)
    let upgrade = ReleaseNotesAnnouncement(defaults: defaults, version: "0.5.6")
    #expect(upgrade.shouldShow)
    upgrade.didShow()
    #expect(!upgrade.shouldShow)
  }

  @Test
  func anUnbundledBuildDoesNotConsumeTheAnnouncement() throws {
    let suite = "GanitReleaseNotesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let announcement = ReleaseNotesAnnouncement(defaults: defaults, version: nil)
    #expect(!announcement.shouldShow)
    announcement.didShow()
    #expect(defaults.string(forKey: ReleaseNotesAnnouncement.seenVersionKey) == nil)
  }
}
