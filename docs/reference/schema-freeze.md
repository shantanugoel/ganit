# Frozen formats

These formats are frozen for the first release. Each has one current
version, which is the only one read or written: any other version is refused
with a clear diagnostic and left untouched. There are no earlier-version
readers, migrations, conversions or downgrades. Changing a format bumps its
version, updates its specification and frozen fixtures, and needs release
notes. `FrozenFormatTests` fails if a version changes without this file.

| Format | Version | Defined in |
| --- | ---: | --- |
| Sheet metadata (`Metadata/<id>.json`) | 2 | `SheetMetadata.currentSchemaVersion`, [sheet files](../storage/sheet-files.md) |
| Folders file | 1 | `SheetFolders`, [library](../workspace/library.md) |
| `.ganit` package manifest | 2 | `GanitManifest.currentSchemaVersion`, [.ganit format](../storage/ganit-format.md) |
| Exchange-rate snapshot metadata | 1 | `RateSnapshotMetadata.currentSchemaVersion`, [currency snapshots](../storage/currency-snapshots.md) |
| Table block (`@ganit-table`) in sheet source | 1 | `TableSourceDocument.currentBlockVersion`, [table blocks](../storage/table-blocks.md) |
| Ambiguity registry (grammar policy) | 8 | [ambiguity registry](../grammar/ambiguity-registry.md) |
| Golden corpus fixtures | 1 | `Tests/GanitEngineCorpusTests/Fixtures` |

Sheet metadata and the package manifest share schema 2 for ordinary and
table-bearing sheets; their fixtures and checksums are in
`Tests/GanitDocumentsTests/Fixtures` and `DocumentFormatFixtureTests`.
Sheet source is plain UTF-8 text and has no version: every Ganit reads it.
Table blocks inside it carry their own version; only version 1 is read, and
other versions stay quarantined with their bytes intact.
Grammar changes that alter an existing answer bump the ambiguity registry and
update the golden corpus in the same change; purely additive syntax that
previously failed to parse does not.
