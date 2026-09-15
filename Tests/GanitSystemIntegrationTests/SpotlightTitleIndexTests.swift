import CoreSpotlight
import Foundation
import Testing

@testable import GanitSystemIntegration

@MainActor
@Suite
struct SpotlightTitleIndexTests {
  @Test
  func sendsOnlyChangedTitlesAndRemovedSheets() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let changes = SpotlightTitleIndex.changes(
      from: [a: "Rent", b: "Trip"],
      to: [a: "Rent", b: "Holiday", c: "Tax"]
    )
    #expect(Set(changes.indexed.map(\.key)) == [b, c])
    #expect(changes.removed.isEmpty)
    #expect(SpotlightTitleIndex.changes(from: [a: "Rent"], to: [:]).removed == [a])
  }

  @Test
  func indexesTitlesOnly() {
    let id = UUID()
    let item = SpotlightTitleIndex.item((id, "Budget"))
    #expect(item.uniqueIdentifier == id.uuidString)
    #expect(item.domainIdentifier == SpotlightTitleIndex.domain)
    #expect(item.attributeSet.title == "Budget")
    #expect(item.attributeSet.textContent == nil)
    #expect(item.attributeSet.contentDescription == nil)
    #expect(SpotlightTitleIndex.item((id, "")).attributeSet.title == "Untitled")
  }

  @Test
  func opensTheSheetASpotlightResultNames() {
    let id = UUID()
    let activity = NSUserActivity(activityType: CSSearchableItemActionType)
    activity.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
    #expect(SpotlightTitleIndex.sheetID(from: activity) == id)
    #expect(SpotlightTitleIndex.sheetID(from: NSUserActivity(activityType: "other")) == nil)
  }
}
