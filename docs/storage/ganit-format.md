# `.ganit` document format, version 1

A `.ganit` document is a macOS document package: a directory with the
`ganit` extension that Finder shows as one file. Its uniform type identifier is
`com.shantanugoel.ganit.sheet`, conforming to `com.apple.package` and
`public.composite-content`.

```text
Example.ganit/
├── source.txt
└── manifest.json
```

The format is decided in [ADR 0004](../adr/0004-storage-and-export.md). It is
the public exchange format; the app's own library layout is described in
[sheet files](sheet-files.md).

## `source.txt`

The sheet's exact source as UTF-8 bytes: no byte-order mark, header, or
front matter, with its original line terminators (`\n`, `\r\n`, or `\r`). It is
readable and editable in any text editor. Readers reject bytes that are not
valid UTF-8.

## `manifest.json`

A JSON object with these keys; writers emit sorted keys and pretty-printed
output.

| Key | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | `1` |
| `id` | string | the sheet's UUID |
| `title` | string | display title |
| `hasCustomTitle` | boolean | whether the title was set by the user rather than taken from the first line |
| `createdAt`, `modifiedAt` | string | ISO 8601 UTC timestamps with second precision |
| `preferences.localeIdentifier` | string | BCP 47 locale the source is parsed with |
| `preferences.angleMode` | string | `radians` or `degrees` |
| `preferences.significantDecimalDigits` | integer | requested display precision, 1–17 |
| `sourceChecksum` | string | `sha256:` and the lowercase hex SHA-256 of `source.txt` |

The manifest never contains answers or other derived data. A reader must reject
any other `schemaVersion`; a future version will be defined with a migration and
a new ADR.

If `source.txt` no longer matches `sourceChecksum`, as after editing it outside
Ganit, the source remains canonical: Ganit imports it and treats the checksum
as stale.

## Writing

A writer creates the complete package in a hidden temporary sibling directory,
flushing each file, then atomically swaps it with an existing package
(`renamex_np` with `RENAME_SWAP`) or renames it into place, and removes the
replaced package. Readers therefore see the previous or the new package.

## Import and export in Ganit

File ▸ Export… writes the open sheet as a Ganit Sheet package or as plain text,
which is exactly `source.txt`'s bytes. File ▸ Import… and opening documents from
Finder add each chosen package or UTF-8 text file to the library as a new sheet.
A package keeps its ID, title, and preferences unless the library already has a
sheet with that ID, in which case it gets a new ID. Plain text gets the default
preferences for new sheets (`en-US`, radians, 15 digits) and a title from its
first line.

Import and export use the sandbox's user-selected read-write file access;
Ganit has no other file-system entitlement.
