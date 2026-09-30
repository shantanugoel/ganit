import AppKit
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct ReferenceFeatureAnnouncementTests {
  @Test
  func announcementWaitsForAnEditorAndAppearsOnce() throws {
    let suite = "GanitReferenceAnnouncementTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let announcement = ReferenceFeatureAnnouncement(defaults: defaults)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    #expect(announcement.shouldShow)
    announcement.show(in: window)
    #expect(announcement.shouldShow)
    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.orderOut(nil)
    }
    announcement.show(in: window)
    #expect(window.attachedSheet != nil)
    #expect(!announcement.shouldShow)
    #expect(!ReferenceFeatureAnnouncement(defaults: defaults).shouldShow)
  }

  @Test
  func announcementDoesNotOverlapTheTour() throws {
    let suite = "GanitReferenceAnnouncementTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let announcement = ReferenceFeatureAnnouncement(defaults: defaults)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFront(nil)
    let tour = NSWindow(contentViewController: TourController {})
    window.beginSheet(tour)
    defer {
      window.endSheet(tour)
      window.orderOut(nil)
    }
    announcement.show(in: window)
    #expect(announcement.shouldShow)
    #expect(window.attachedSheet === tour)
  }
}
