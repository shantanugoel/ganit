import Foundation
import GanitDocuments

/// A group of sheets shown in the sidebar.
public enum SheetCollection: Codable, Hashable, Sendable {
  case all
  case recent
  case favorites
  case folder(UUID)
  case archive
  case trash

  /// Sheets modified within this interval are recent.
  static let recentInterval: TimeInterval = 7 * 86_400

  /// The collection's sheets among `summaries`, keeping their order.
  func sheets(in summaries: [SheetSummary], now: Date) -> [SheetSummary] {
    summaries.filter { summary in
      switch self {
      case .all:
        return summary.state == .active
      case .recent:
        return summary.state == .active
          && now.timeIntervalSince(summary.modifiedAt) <= Self.recentInterval
      case .favorites:
        return summary.state == .active && summary.isFavorite
      case .folder(let id):
        return summary.state == .active && summary.folderID == id
      case .archive:
        return summary.state == .archived
      case .trash:
        return summary.state == .trashed
      }
    }
  }
}

extension SheetLibrary {
  /// A collection's sheets, most recently modified first, narrowed to those
  /// whose title or source contains `search` when it is not empty.
  func sheets(in collection: SheetCollection, matching search: String, now: Date) throws
    -> [SheetSummary]
  {
    let sheets = collection.sheets(in: try index.summaries(), now: now)
    guard !search.isEmpty else {
      return sheets
    }
    let matches = Set(try index.search(search))
    return sheets.filter { matches.contains($0.id) }
  }
}
