import AppIntents
import AppKit
import Foundation

/// A title that names no sheet, reported rather than opening something else.
public struct NoSuchSheet: Error, LocalizedError, Equatable, Sendable {
  public let title: String

  public var errorDescription: String? {
    "No sheet is titled “\(title)”."
  }
}

/// The sheet windows Open Sheet needs, which only the running app has. The
/// application delegate implements it.
@MainActor
public protocol SheetOpening: AnyObject {
  /// Shows the sheet a title names, answering whether the library has one.
  /// The library's own title lookup decides what a title matches, so the
  /// intent has no rules of its own.
  func revealSheet(titled title: String) -> Bool
}

/// Open Sheet, the action Shortcuts offers for reaching a sheet by name.
///
/// Unlike Calculate Expression, this one is about windows rather than answers,
/// so it opens the app and returns nothing.
public struct OpenSheetIntent: AppIntent {
  public static let title: LocalizedStringResource = "Open Sheet"

  public static let description = IntentDescription(
    "Opens the Ganit sheet with this title.",
    categoryName: "Sheets"
  )

  public static let openAppWhenRun = true

  @Parameter(
    title: "Title",
    description: "The title of the sheet to open."
  )
  public var sheetTitle: String

  public init() {}

  public init(sheetTitle: String) {
    self.sheetTitle = sheetTitle
  }

  public func perform() async throws -> some IntentResult {
    let title = sheetTitle
    let opened = await MainActor.run {
      (NSApplication.shared.delegate as? any SheetOpening)?.revealSheet(titled: title) ?? false
    }
    guard opened else {
      throw NoSuchSheet(title: title)
    }
    return .result()
  }
}
