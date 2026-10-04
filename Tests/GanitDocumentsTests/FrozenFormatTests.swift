import Foundation
import GanitData
import GanitEngine
import Testing

@testable import GanitDocuments

/// Frozen format versions; see docs/reference/schema-freeze.md before
/// changing any of them.
@Test
func formatVersionsMatchTheFreeze() throws {
  #expect(SheetMetadata.currentSchemaVersion == 2)
  #expect(GanitManifest.currentSchemaVersion == 2)
  #expect(RateSnapshotMetadata.currentSchemaVersion == 1)
  #expect(TableSourceDocument.currentBlockVersion == 1)

  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let registry = try String(
    contentsOf: repository.appending(path: "docs/grammar/ambiguity-registry.md"), encoding: .utf8)
  #expect(registry.contains("**Registry version:** 8"))
  let freeze = try String(
    contentsOf: repository.appending(path: "docs/reference/schema-freeze.md"), encoding: .utf8)
  #expect(freeze.contains("| Ambiguity registry (grammar policy) | 8 |"))
  #expect(freeze.contains("| Table block (`@ganit-table`) in sheet source | 1 |"))
  #expect(freeze.contains("| Sheet metadata (`Metadata/<id>.json`) | 2 |"))
  #expect(freeze.contains("| `.ganit` package manifest | 2 |"))
}
