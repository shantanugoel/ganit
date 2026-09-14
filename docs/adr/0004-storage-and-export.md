# ADR 0004: Keep canonical source separate and export `.ganit` packages

- Status: Accepted
- Date: 2026-09-14

## Context

A sheet must remain recoverable when metadata or the search index is corrupt. Internal storage must support atomic source updates, independent metadata, backups, checksums, and multiple windows. Public documents must preserve source bytes and enough metadata for stable identity and future interpretation without inventing an ambiguous front-matter escape grammar.

## Decision

Use the application-support layout defined in `PLAN.md`:

- `Sheets/<UUID>.txt` is the canonical UTF-8 source.
- `Metadata/<UUID>.json` is versioned metadata with a source checksum.
- `Index/index.sqlite` is derived and rebuildable.
- `Backups/` contains bounded, restorable snapshots.
- `Data/` contains validated versioned datasets.

Write source and metadata through sibling temporary files, sync where durability requires it, and atomically replace the destination. A sheet is discoverable by scanning source and metadata files without the index. Derived answers are never authoritative.

Define `.ganit` as a macOS document package with schema version 1:

```text
Example.ganit/
├── source.txt
└── manifest.json
```

`source.txt` contains the exact UTF-8 source with no injected header. `manifest.json` contains only portable, documented metadata and a checksum of `source.txt`; it never contains answer caches. Package writes use a complete temporary sibling package followed by atomic replacement. Plain `.txt` remains a first-class import/export format when metadata is not needed.

The first public schema will be frozen before beta. Until then, unsupported schemas fail explicitly; there are no legacy readers, dual writes, or compatibility aliases. After a public schema exists, a format change requires a tested one-way migration with a pre-migration backup and a new ADR.

## Consequences

- Source is directly recoverable and byte-for-byte round trips are testable.
- The package avoids front-matter collisions and leaves room for portable metadata without changing source text.
- Finder presents `.ganit` as one document while command-line users can inspect its standard files.
- Storage tests must inject interruption around every write stage and prove old-or-new completeness, index rebuild, checksum detection, and actual restore.

## References

- [File System Programming Guide: File System Basics](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
- [File packages](https://developer.apple.com/documentation/foundation/filewrapper)
