import AppIntents
import AppKit
import Foundation
import Testing

@testable import GanitSystemIntegration

/// The intent reads the application delegate, so these run one at a time and
/// put the delegate back afterwards.
@Suite(.serialized)
@MainActor
struct OpenSheetIntentTests {
  @Test
  func opensTheAppOnTheSheetATitleNames() async throws {
    #expect(OpenSheetIntent.openAppWhenRun)
    let app = FakeApplication(libraryHas: true)
    try await withDelegate(app) {
      _ = try await OpenSheetIntent(sheetTitle: "Rent").perform()
    }

    #expect(app.asked == ["Rent"])
  }

  @Test
  func reportsATitleThatNamesNoSheet() async throws {
    let app = FakeApplication(libraryHas: false)
    try await withDelegate(app) {
      await #expect(throws: NoSuchSheet(title: "Nothing")) {
        try await OpenSheetIntent(sheetTitle: "Nothing").perform()
      }
    }

    #expect(app.asked == ["Nothing"])
  }

  /// Runs `body` with `delegate` installed, restoring the previous one.
  private func withDelegate(
    _ delegate: FakeApplication,
    _ body: () async throws -> Void
  ) async throws {
    let previous = NSApplication.shared.delegate
    NSApplication.shared.delegate = delegate
    defer { NSApplication.shared.delegate = previous }
    try await body()
  }
}

/// Stands in for the app, recording the titles it was asked to show.
@MainActor
private final class FakeApplication: NSObject, NSApplicationDelegate, SheetOpening {
  private(set) var asked: [String] = []
  private let libraryHas: Bool

  init(libraryHas: Bool) {
    self.libraryHas = libraryHas
  }

  func revealSheet(titled title: String) -> Bool {
    asked.append(title)
    return libraryHas
  }
}
