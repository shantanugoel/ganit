# Frozen formats

These formats are frozen for the first release. Changing any of them is a
compatibility change: bump its version, keep reading every earlier version or
refuse it with a clear diagnostic, add migration fixtures, and write release
notes. `FrozenFormatTests` fails if a version changes without this file.

| Format | Version | Defined in |
| --- | ---: | --- |
| Sheet metadata (`Metadata/<id>.json`) | 1 | `SheetMetadata.currentSchemaVersion`, [sheet files](../storage/sheet-files.md) |
| Folders file | 1 | `SheetFolders`, [library](../workspace/library.md) |
| `.ganit` package manifest | 1 | `GanitManifest.currentSchemaVersion`, [.ganit format](../storage/ganit-format.md) |
| Exchange-rate snapshot metadata | 1 | `RateSnapshotMetadata.currentSchemaVersion`, [currency snapshots](../storage/currency-snapshots.md) |
| Ambiguity registry (grammar policy) | 8 | [ambiguity registry](../grammar/ambiguity-registry.md) |
| Golden corpus fixtures | 1 | `Tests/GanitEngineCorpusTests/Fixtures` |

Sheet source is plain UTF-8 text and has no version: every Ganit reads it.
Grammar changes that alter an existing answer bump the ambiguity registry and
update the golden corpus in the same change; purely additive syntax that
previously failed to parse does not.
