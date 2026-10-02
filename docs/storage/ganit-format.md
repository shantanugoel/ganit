# `.ganit` document format, version 2

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

The sheet's exact source as UTF-8 bytes: no header or front matter, with its
original line terminators (`\n`, `\r\n`, or `\r`), table blocks, identities,
bindings, `#REF!` markers, and malformed or unknown blocks as written. It is
readable and editable in any text editor. Nothing is normalized: U+0085,
U+2028, U+2029, decomposed characters, and a missing final line terminator
are kept.

Writers never add a byte-order mark. Readers remove one leading UTF-8
byte-order mark (`EF BB BF`), which some editors add as an encoding
signature rather than text, so a table block on the first line stays a
table block; every other byte, including a second U+FEFF or one later in
the text, is kept. This is the one exception to exact bytes, recorded in
[ADR 0017](../adr/0017-table-source-and-storage.md): Ganit stores and exports
a sheet whose own text begins with U+FEFF with that character, but importing
the exported file removes it. Readers reject bytes that are not valid UTF-8,
such as UTF-16, rather than decoding them lossily.

## `manifest.json`

A JSON object with these keys; writers emit sorted keys and pretty-printed
output.

| Key | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | `2` |
| `id` | string | the sheet's UUID |
| `title` | string | display title |
| `hasCustomTitle` | boolean | whether the title was set by the user rather than taken from the first line |
| `createdAt`, `modifiedAt` | string | ISO 8601 UTC timestamps with second precision |
| `preferences.localeIdentifier` | string | BCP 47 locale the source is parsed with |
| `preferences.angleMode` | string | `radians` or `degrees` |
| `preferences.significantDecimalDigits` | integer | requested display precision, 1–17 |
| `preferences.display` | object | how the sheet writes its answers, with every display choice written |
| `sourceChecksum` | string | `sha256:` and the lowercase hex SHA-256 of the source: `source.txt` without one leading byte-order mark |
| `tables` | object | presentation-only table state; may be `{}` |

Every key is required; a manifest missing one fails to decode, as does one
whose `tables` is invalid. The manifest never contains answers or other derived
data, and `tables` is never canonical:
the table blocks in `source.txt` win. `tables` follows the rules in
[sheet metadata](sheet-files.md#table-presentation): a writer keeps only valid
entries whose identities occur in the source. When the presentation would
make the manifest larger than import accepts, the writer leaves it out rather
than fail. A writer refuses to export a package whose source, or whose
manifest without presentation, is larger than import accepts, and writes
nothing.

Schema 2 is the only manifest schema, for ordinary and table-bearing sheets
alike. A reader rejects any other `schemaVersion`, including `1`, with
`unsupportedSchemaVersion`. There is no migration, conversion or downgrade
export.

If `source.txt` no longer matches `sourceChecksum`, as after editing it outside
Ganit, the source remains canonical: Ganit imports it without a warning and
never substitutes anything cached. The imported sheet gets a new checksum of
that source and keeps the manifest's `id`, `title`, `hasCustomTitle`,
`createdAt`, and `preferences`; a title that follows the first line follows
the new source, and `tables` keeps only valid entries whose identities occur
in it, as on every save. The checksum is compared with the source after
removing one leading byte-order mark.

## Size limits

Import refuses a `source.txt` or plain-text file whose source, not counting
a byte-order mark, is larger than 1,048,576 bytes (1 MiB, the engine's
source limit), and a `manifest.json` larger than 65,536 bytes. A refused file
is never truncated, and nothing is written to the library. A source of
exactly 1,048,576 bytes imports. These refusals, and refusals of bytes that
are not UTF-8, name the chosen file or package, not a file inside it.

## Writing

A writer creates the complete package in a hidden temporary sibling directory,
flushing each file, then atomically swaps it with an existing package
(`renamex_np` with `RENAME_SWAP`) or renames it into place, and removes the
replaced package. Readers therefore see the previous or the new package. An
interrupted export can leave the hidden temporary sibling behind; see
[fault tolerance](fault-tolerance.md).

## Import and export in Ganit

File ▸ Export… writes the open sheet as a Ganit Sheet package or as plain text,
which is exactly `source.txt`'s bytes: the sheet's stored source bytes,
unchanged. Plain-text export writes the whole source, even one too large to
import again. File ▸ Export… can also write PDF, CSV, or HTML, which show each
line beside its answer; they are one-way presentations, not a sheet's source.
There is no export in an earlier package format. A file name ending in
`.ganit` in any case is a package.

File ▸ Import… and opening documents from Finder add each chosen package or
UTF-8 text file to the library as a new sheet whose source is the file's
bytes, less one leading byte-order mark. A package keeps its ID, title,
preferences, and table presentation unless the library already has a sheet
with that ID, in which case it gets a new ID. The source is unchanged either
way, so table, row, column, and binding identities are never reminted: they
need only be unique within a sheet, no sheet refers to another sheet's tables,
and reminting them would rewrite the source. Plain text gets the default
preferences for new sheets (`en-US`, radians, 15 digits) and a title from its
first line.

Import and export use the sandbox's user-selected read-write file access;
Ganit has no other file-system entitlement.
