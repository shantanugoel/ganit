import Foundation
import GanitData
import Testing

@testable import GanitDocuments

/// Frozen format versions; see docs/reference/schema-freeze.md before
/// changing any of them.
@Test
func formatVersionsMatchTheFreeze() throws {
  #expect(SheetMetadata.currentSchemaVersion == 1)
  #expect(GanitManifest.currentSchemaVersion == 1)
  #expect(RateSnapshotMetadata.currentSchemaVersion == 1)

  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let registry = try String(
    contentsOf: repository.appending(path: "docs/grammar/ambiguity-registry.md"), encoding: .utf8)
  #expect(registry.contains("**Registry version:** 5"))
  let freeze = try String(
    contentsOf: repository.appending(path: "docs/reference/schema-freeze.md"), encoding: .utf8)
  #expect(freeze.contains("| Ambiguity registry (grammar policy) | 5 |"))
}
