import Foundation
import Testing

@testable import GanitEngine

@Test
func engineModuleLoadsWithoutApplicationFrameworks() {
  // Importing this target independently verifies the Phase 0 package boundary.
}

@Test
func engineSourcesDoNotImportUIFrameworks() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let engineDirectory = repositoryRoot.appending(path: "Sources/GanitEngine")
  let sourceURLs = try #require(
    FileManager.default.enumerator(
      at: engineDirectory,
      includingPropertiesForKeys: nil
    )?.compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
  )

  for sourceURL in sourceURLs {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(!source.contains("import AppKit"))
    #expect(!source.contains("import SwiftUI"))
  }
}
