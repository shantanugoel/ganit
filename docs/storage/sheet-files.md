# Sheet files

`SheetStore` (in `GanitDocuments`) keeps each sheet as two files under a library
root, as decided in [ADR 0004](../adr/0004-storage-and-export.md):

```text
<root>/
├── Sheets/<UUID>.txt      canonical UTF-8 source, byte for byte
└── Metadata/<UUID>.json   versioned metadata
```

Source files contain exactly the editor's text with no header or byte-order
mark, so line terminators and every character round trip. Loading source that
is not valid UTF-8 fails with `DocumentStorageError.invalidUTF8` instead of
decoding lossily.

## Metadata, schema version 1

| Key | Meaning |
|---|---|
| `schemaVersion` | `1`; any other version fails with `unsupportedSchemaVersion` |
| `id` | stable sheet UUID, matching both file names |
| `title` | display title |
| `folderID` | containing folder, if any |
| `createdAt`, `modifiedAt` | ISO 8601 UTC timestamps, second precision |
| `isFavorite` | favorite flag |
| `state` | `active`, `archived`, or `trashed` |
| `preferences` | `localeIdentifier`, `angleMode`, and `significantDecimalDigits` |
| `sourceChecksum` | `sha256:` and the lowercase hex SHA-256 of the source bytes |

JSON is pretty-printed with sorted keys so files stay readable and stable.

## Atomic replacement

Every write goes to a uniquely named hidden sibling (`.<name>.<UUID>.tmp`), is
flushed with `F_FULLFSYNC`, renamed over the destination, and followed by a
directory `fsync`. A reader or a recovering launch sees the previous or the new
complete file. A failed write removes its temporary file and leaves the
destination untouched.

`save` writes source before metadata and stamps the metadata with the new
checksum. If a save is interrupted between the two, the new source remains with
metadata whose checksum does not match; `load` reports this as
`isChecksumValid == false`, and the source stays canonical.

`sheetIDs()` discovers sheets by scanning `Sheets/`, ignoring temporary files
and other names, so no index is needed to find every sheet.
