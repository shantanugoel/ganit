import CoreSpotlight
import Foundation
import GanitDocuments
import UniformTypeIdentifiers

/// The optional Spotlight index of sheet titles.
///
/// Only the titles of active sheets are indexed, never source text, answers,
/// folders, or dates, so Spotlight reveals no more than a sheet's name. It is
/// off unless the user turns it on, and turning it off removes every item.
@MainActor
public final class SpotlightTitleIndex {
  public nonisolated static let domain = "com.shantanugoel.Ganit.sheetTitles"

  private let index: CSSearchableIndex
  /// The titles last sent to Spotlight, or `nil` before the first update.
  private var indexed: [UUID: String]?

  public init(index: CSSearchableIndex = .default()) {
    self.index = index
  }

  /// Brings Spotlight to the titles of the active sheets in `summaries`,
  /// sending only what changed. The first update replaces whatever an
  /// earlier launch indexed.
  public func update(_ summaries: [SheetSummary]) {
    let titles = Dictionary(
      summaries.filter { $0.state == .active }.map { ($0.id, $0.title) },
      uniquingKeysWith: { first, _ in first })
    guard let indexed else {
      index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { [index] _ in
        index.indexSearchableItems(titles.map(Self.item))
      }
      self.indexed = titles
      return
    }
    let changes = Self.changes(from: indexed, to: titles)
    if !changes.removed.isEmpty {
      index.deleteSearchableItems(withIdentifiers: changes.removed.map(\.uuidString))
    }
    if !changes.indexed.isEmpty {
      index.indexSearchableItems(changes.indexed.map(Self.item))
    }
    self.indexed = titles
  }

  public func removeAll() {
    index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    indexed = nil
  }

  /// Titles to add or replace, and sheets to remove.
  nonisolated static func changes(from old: [UUID: String], to new: [UUID: String]) -> (
    indexed: [(key: UUID, value: String)], removed: [UUID]
  ) {
    (
      new.filter { old[$0.key] != $0.value }.sorted { $0.key.uuidString < $1.key.uuidString },
      old.keys.filter { new[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
    )
  }

  /// A title-only item for a sheet.
  nonisolated static func item(_ sheet: (key: UUID, value: String)) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    attributes.title =
      sheet.value.isEmpty ? localized("sheet.untitled", "Untitled") : sheet.value
    return CSSearchableItem(
      uniqueIdentifier: sheet.key.uuidString, domainIdentifier: domain,
      attributeSet: attributes)
  }

  /// The sheet a Spotlight result opens.
  public static func sheetID(from activity: NSUserActivity) -> UUID? {
    guard activity.activityType == CSSearchableItemActionType,
      let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    else {
      return nil
    }
    return UUID(uuidString: identifier)
  }
}
