# Derived index

`SheetIndex` (in `GanitDocuments`) keeps `<root>/Index/index.sqlite`, a derived
copy of each sheet's listing fields (title, folder, state, favorite, modified
time) and source. Sheet files remain the only authority: the index can be
deleted at any time without losing content.

It uses the system SQLite library directly through a small adapter; there is no
ORM. The table schema version is stored in `PRAGMA user_version` (currently 1).

## Health and rebuild

Opening the index runs `PRAGMA quick_check` and reads the schema version. A
corrupt file, or one with another schema version, is deleted with its journal
files and replaced by an empty index. A new or replaced index reports
`needsRebuild`.

`rebuild(from:)` replaces the index contents in one transaction with every sheet
`SheetStore` can read. Sheets whose source or metadata cannot be read are listed
in the report's `unreadable`; their files are never modified by indexing.

## Queries

- `summaries()` lists sheets by most recent modification.
- `search(_:)` returns sheets whose title or source contains the text, ignoring
  case and diacritics, in the same order.

Search scans indexed rows rather than using SQLite full-text search, which is
added only if profiling at the target library size shows the scan is too slow.
Text is stored and read by byte length, so source containing any character,
including NUL, is indexed intact.
