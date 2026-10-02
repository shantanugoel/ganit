# Sheet files

`SheetStore` (in `GanitDocuments`) keeps each sheet as two files under a library
root, as decided in [ADR 0004](../adr/0004-storage-and-export.md):

```text
<root>/
├── Sheets/<UUID>.txt      canonical UTF-8 source, byte for byte
└── Metadata/<UUID>.json   versioned metadata
```

Source files contain exactly the editor's text with no header or byte-order
mark, so line terminators and every character round trip. Calculation tables are
[table blocks](table-blocks.md) inside that text, not separate files. Loading source that
is not valid UTF-8 fails with `DocumentStorageError.invalidUTF8` instead of
decoding lossily.

## Metadata, schema version 2

Schema 2 is the only metadata schema, for ordinary and table-bearing sheets
alike. Every key below is required except `folderID`; a file missing one, or
holding an invalid value, fails to decode.

| Key | Meaning |
|---|---|
| `schemaVersion` | `2`; any other version, including `1`, fails with `unsupportedSchemaVersion` and is never converted |
| `id` | stable sheet UUID, matching both file names |
| `title` | display title |
| `folderID` | containing folder, if any |
| `createdAt`, `modifiedAt` | ISO 8601 UTC timestamps, second precision |
| `isFavorite` | favorite flag |
| `state` | `active`, `archived`, or `trashed` |
| `hasCustomTitle` | whether the user named the sheet rather than its title following the first line |
| `preferences` | `localeIdentifier`, `angleMode`, `significantDecimalDigits`, and `display`, how the sheet writes its answers, with every display choice written |
| `sourceChecksum` | `sha256:` and the lowercase hex SHA-256 of the source bytes |
| `tables` | presentation-only table state; may be `{}` |

JSON is pretty-printed with sorted keys so files stay readable and stable.

### Table presentation

`tables` maps each table's canonical lowercase TableID to its presentation:

```json
"tables" : {
  "10000000-0000-4000-8000-000000000001" : {
    "columnWidths" : {
      "10000000-0000-4000-8000-000000000011" : 120
    }
  }
}
```

`columnWidths` maps canonical lowercase ColumnIDs to finite widths in points,
from 1 to 10,000. An entry has no other keys. This state is never canonical:
the [table block](table-blocks.md) in the source wins.

Reading is strict. Any other identity spelling, width, or entry key makes the
whole metadata file invalid, as does an entry without `columnWidths`, like
any other corrupt metadata: recovery moves
it to `Quarantine/` and rebuilds metadata from the source, so the sheet keeps
its source and tables but its title, folder, favorite flag, state,
preferences, and widths reset. JSON with a duplicated key is read with the
first value, as Foundation's decoder does.

Writing never fails because of presentation. `TablePresentations.setWidth`
ignores invalid identities and non-finite widths and clamps widths to the
range. Writers drop any invalid entry still in memory, and drop table and
column entries whose identity no longer occurs, byte for byte, anywhere in
the saved source, so the map cannot outgrow the sheet. A malformed block that
still names its identities keeps its entries. Widths are lost when a table is
absent from a save, such as an autosave between cutting and pasting it, or
when a block spells an identity with JSON escapes rather than its plain
canonical text, or when exporting a package whose manifest they would make
larger than import accepts; only presentation is lost.

## Atomic replacement

Every write goes to a uniquely named hidden sibling (`.<name>.<UUID>.tmp`), is
flushed with `F_FULLFSYNC`, renamed over the destination, and followed by a
directory `fsync`. A reader or a recovering launch sees the previous or the new
complete file. A failed write removes its temporary file and leaves the
destination untouched. A write the process cannot finish, such as one killed
partway, leaves its temporary file. Library recovery, when it runs, removes
such files from `Sheets/` and `Metadata/` only, where it can; see
[fault tolerance](fault-tolerance.md).

`save` encodes metadata first, so metadata that cannot be written leaves both
files untouched, then writes source before metadata and stamps the metadata
with the new checksum. If a save is interrupted between the two, the new source remains with
metadata whose checksum does not match; `load` reports this as
`isChecksumValid == false`, and the source stays canonical.

`sheetIDs()` discovers sheets by scanning `Sheets/`, ignoring temporary files
and other names, so no index is needed to find every sheet.
