# Table blocks, format version 1

A calculation table lives inside ordinary sheet source as a delimited block,
as decided in [ADR 0016](../adr/0016-table-semantics-and-editor-ownership.md)
and [ADR 0017](../adr/0017-table-source-and-storage.md). This page freezes the
wire format. `GanitEngine` reads it with `TableSourceDocument` and writes it
with `TableSourceDocument.canonicalBlock(for:lineEnding:)`.

Version 1 is the only supported version. There is no reader, migration or
conversion for any other version: a block naming another version is
diagnosed and quarantined with its bytes intact. A change to anything on this
page is a new block version and updates the [frozen formats](../reference/schema-freeze.md),
the fixtures in `Tests/GanitEngineTests/Fixtures/TableBlocks` and their
checksums in `TableBlockFixtureTests`.

## Block delimiters

```text
@ganit-table 1
{"ids":[…],"t":0,"n":"Items","c":[…],"r":[…],"x":[…],"b":[…]}
@end-ganit-table
```

Sheet source is split into physical lines at `\n`, `\r\n` and `\r` only;
U+0085, U+2028 and U+2029 do not end a line. Blocks are recognized before
ordinary or Markdown line classification, in both sheet modes.

- A physical line that starts with `@ganit-table` followed by the end of the
  line, a space or a tab is a block opener. Leading whitespace, other
  spellings (`@ganit-tables`, `@GANIT-TABLE`) and Markdown pipe tables are
  ordinary prose.
- Exactly `@ganit-table 1` opens a version 1 block.
- `@ganit-table` followed by one space and a canonical decimal integer other
  than `1` (`0`, `2`, …) is an **unsupported version**.
- Any other opener (`@ganit-table`, `@ganit-table 1 `, `@ganit-table  1`,
  `@ganit-table\t1`, `@ganit-table 01`) is **malformed**.
- The first later physical line that is exactly `@end-ganit-table` closes the
  block. Its terminator, if any, belongs to the block.
- An opener without a closer is **unterminated**: the block runs to the end of
  the sheet and contains any later opener. Repair is an explicit edit.

The payload is every byte between the opener's terminator and the closer's
line. JSON escapes CR and LF inside strings, so payload text cannot close its
block. Bytes are never normalized, re-encoded or trimmed.

Every block line, valid or not, is quarantined from ordinary calculation: it
has no scalar answer, declares nothing, never asks the assistant, and ends the
ordinary aggregate block (`total`, `subtotal`, `previous`) before and after the
table without clearing variables. A block with any diagnostic has no
projection; Ganit never substitutes a previous valid table.

### Retention while editing

A malformed, unsupported, unterminated, stale or conflicting block is kept
byte for byte while a sheet is edited, saved, closed, reopened or restored.
Each evaluation segments the current source again and reports that source's
diagnostics; a block whose bytes are unchanged reuses its parse, but
sheet-wide checks (names, identities, cross-table targets, the cell and byte
limits) run on every evaluation, so an edit elsewhere can withhold or restore
a projection. The editor commits only the newest evaluation, so a superseded
generation never shows an older valid table after a newer invalid one.

No automatic rewrite changes bytes inside a block. Line-reference renumbering
skips lines that are in a block before or after the edit, and editor
conveniences (completion, scrubbing, inserted lines and references, prefix
toggles, reinterpretation) do not act on block lines; see the
[text view](../editor/text-view.md#table-blocks). Explicit user edits, such
as typing, pasting, deleting or Find and Replace, change exactly the bytes
edited, and Undo restores them exactly.
Deleting a closer extends the block to the next closer, or quarantines it
through the end of the sheet; restoring the closer is the repair.

## Payload JSON

The payload is one JSON object with surrounding JSON whitespace (space, tab,
CR, LF). Parsing is stricter than general JSON readers:

- Duplicate object keys are rejected, compared after decoding escapes, so
  `{"x":1,"x":2}` is a duplicate.
- Trailing commas, leading zeros, `+1`, `.5`, `1.`, `NaN`, `Infinity`, unknown
  escapes, raw control characters in strings and unpaired UTF-16 surrogate
  escapes (`"\ud800"`) are rejected; nothing is replaced.
- Nesting is limited to 32 levels.
- Numbers keep their exact lexeme; nothing passes through floating point.
- Keys not defined below are allowed anywhere, ignored, and kept byte for byte
  because edits patch spans rather than re-encoding the block.

### Identities and pointers

Each table has a TableID, each row a RowID, each column a ColumnID, and each
range or structured binding a BindingID. A data cell's identity is its
(TableID, RowID, ColumnID); a header's is (TableID, ColumnID). There are no
per-cell UUIDs.

Identities are UUIDs spelled in canonical lowercase 36-character form
(`8-4-4-4-12` hexadecimal digits); any other spelling, including uppercase or
braces, is malformed, because broken markers compare identities as text.
They are interned in the `ids` dictionary: every other identity field is a
**pointer**, a JSON integer spelled without sign, fraction or exponent that
indexes `ids`. Pointers are wire positions only; readers resolve them to
UUIDs immediately, and an edit never reuses a pointer for a different
identity. Dictionary entries are unique. Entries that nothing points to are
allowed and ignored; IDs of deleted targets stay in the dictionary while a
binding still names them.

Within a block every UUID has one role (table, row, column or binding).
Across a sheet each table, row, column and binding identity is defined by one
block only.

### Root object

| Key | Type | Meaning |
| --- | --- | --- |
| `ids` | array of strings | the identity dictionary |
| `t` | pointer | TableID |
| `n` | string | table name |
| `c` | array of column objects | columns in order; at least one |
| `r` | array of pointers | RowIDs in data-row order; may be empty |
| `x` | array of cell objects | populated cell records |
| `b` | array of ledger entries | formula bindings by owner |

All seven keys are required.

A table name is non-empty single-line text without leading or trailing
whitespace or control characters (including U+2028/U+2029), and is not
`sheet` in any case. Names are unique in a sheet ignoring case, including
across dividers. Case-insensitive comparisons use Unicode lowercase mapping
and canonical equivalence; stored bytes are never normalized.

### Column object

| Key | Type | Meaning |
| --- | --- | --- |
| `i` | pointer | ColumnID |
| `h` | string | header text |
| `p` | `"value"` or `"text"` | input policy for literal input |
| `u` | string, optional | default unit for value literals: non-empty single-line text without outer whitespace |
| `m` | string, optional | default currency for value literals: three uppercase ASCII letters |
| `f` | string, optional | column rule: a formula starting with `=` |
| `z` | string, optional | totals-footer aggregate: `sum`, `average`, `median`, `min`, `max` or `count` |

Headers follow the name rules above, except that `sheet` is an ordinary
header, and are unique within the table ignoring case. Header text is literal: it is never parsed as units, variables or
syntax. `u` and `m` are allowed only on value columns, and at most one of
them. Their meaning, like the interpretation of value literals, belongs to the
calculator; they are canonical source because they change interpretation.
The totals footer reads data rows only and has no data-row address.

### Cell object

| Key | Type | Meaning |
| --- | --- | --- |
| `a` | `[row, column]` pointers | a live data cell |
| `s` | string | exact input source |
| `o` | `true`, optional | the record overrides its column's rule |

A cell without a record is blank, or inherits its column's rule. A source that
starts with `=` is a formula, whatever the input policy; literal text cannot
start with `=` in version 1. Otherwise a value column reads `s` as a complete
literal and a text column keeps it as text. Multi-line text is allowed.

- In a column without a rule, records have `o` absent and non-empty `s`:
  blank is the absence of a record.
- In a column with a rule, every record has `"o":true`. `"s":""` is a blank
  override, distinct from removing the record, which inherits the rule again.
- `o` is spelled only as `true`; `"o":false` is malformed.
- Each data cell has at most one record.

### Ledger entry

| Key | Type | Meaning |
| --- | --- | --- |
| `o` | `[row, column]` or `[null, column]` | owner: a data cell, or the column's rule |
| `f` | string | fingerprint: the owner's exact source when the ledger was written |
| `e` | array of bindings | bound operands in source order; at least one |

`[null, column]` always means the column rule, never the header: headers own
no formulas. The owner's source (cell `s` or column `f`) must start with `=`
and equal `f` byte for byte, so a formula changed without its ledger is
**stale**. A formula without bound references has no entry. Each owner has at
most one entry.

### Binding object

| Key | Type | Meaning |
| --- | --- | --- |
| `i` | pointer | BindingID; required for every kind except `cell`, and absent for `cell` |
| `k` | string | reference form, below |
| `a` | `[start, end]` integers | the operand's UTF-8 byte span in the decoded owner source |
| `t` | array | target, shaped by `k` and `d` |
| `l` | array of `0`/`1` | copy locks per endpoint axis; required with the count below, and absent for `named` and `current` |
| `d` | `true`, optional | the target was deleted |

Spans count bytes of the decoded owner string, including its leading `=`;
they start after the `=`, never split a Unicode scalar, are non-empty and
appear in increasing, non-overlapping order. A binding's position in `e` is
its occurrence ordinal; there is no separate ordinal field.

| `k` | Source form | Live `t` | Deleted `t` | `l` |
| --- | --- | --- | --- | --- |
| `cell` | `B2`, `$B$2`, `Rates!B2`, header `B1` | `[table, row or null, column]` | same; the target no longer exists | `[row, column]` |
| `rect` | `B2:D6` | `[table, firstRow, firstColumn, lastRow, lastColumn]` | `[table, [rows…], [columns…]]` | `[startRow, startColumn, endRow, endColumn]` |
| `cols` | `C:C`, `C:E` | `[table, firstColumn, lastColumn]` | `[table, [columns…]]` | `[start, end]` |
| `rows` | `2:2`, `2:4` | `[table, firstRow, lastRow]` | `[table, [rows…]]` | `[start, end]` |
| `named` | `Items[Amount]` | `[table, column]` | same; the column no longer exists | none |
| `current` | `[@Qty]` | `[column]` in the owner's table | same; the column no longer exists | none |

A `null` row in a `cell` target is the header cell. Rectangles and row ranges
cover data rows only. Live ranges are inclusive intervals over the target
table's ordered IDs; both endpoints must exist and the first must not follow
the last on either axis. `cols` and `rows` ranges include every data row or
column of their members, and `named` follows the column's current data
membership; `named` and `current` never translate on copy or fill. Locks say
which axes stay fixed on copy and fill; they never change which identity is
bound. Only `current` is limited to the owner's own table.

A deleted range keeps its original ordered members, unique and non-empty on
each axis, and at least one axis has no surviving member. A deleted target
must not exist: a marker can never hide, or bind to, a reused coordinate.

#### Broken markers

A deleted binding's operand must spell its marker exactly, and a live
binding's operand must not start with `#REF!`:

- `cell`: `#REF!{<table-id>/<row-id>/<column-id>}`, with `header` in place of
  the row ID for a header target.
- every other kind: `#REF!{range:<binding-id>}`.

IDs are spelled in canonical lowercase. Repair replaces the complete operand.

## Validation and diagnostics

`TableSourceDocument` reports a `TableSourceDiagnostic` per problem with a
stable code and the affected UTF-8 range (the payload for payload problems,
otherwise the block). Diagnostics never change source.

| Code | Scope | Meaning |
| --- | --- | --- |
| `malformed` | block | misspelled opener, invalid JSON, or a known field that is missing, mistyped, present where its record forbids it, or of the wrong arity or form (including lock counts, binding IDs, and interval versus retained membership) |
| `unsupportedVersion` | block | well-formed opener with another version |
| `unterminated` | block | opener without closer, quarantined to the end of the sheet |
| `invalidRecord` | block | a well-shaped record whose values break a rule above, such as a reserved name, a duplicate header or a range whose first endpoint follows its last |
| `duplicateIdentity` | block or sheet | a repeated dictionary entry, cell record or membership ID, an identity with two roles, or an identity defined by two blocks |
| `duplicateName` | sheet | table names equal ignoring case |
| `staleBinding` | block or sheet | a fingerprint mismatch, an owner that is not a formula, a misplaced span, a wrong marker, or a deleted target that still exists |
| `orphanTarget` | block or sheet | a cell record or live binding naming a missing row, column or table |
| `cellLimit` | sheet | more than 4,000 populated cells in the sheet's tables |
| `sourceLimit` | sheet | sheet source over 1,048,576 UTF-8 bytes; checked before any payload is decoded, so such a sheet decodes no JSON |

Sheet-wide checks withhold every affected projection instead of choosing a
winner. Targets in other tables are checked against the valid blocks of the
sheet; when a table is rejected its readers are checked again, until nothing
changes. The fixed point is conservative: a reader rejected in one round, for
example because its deleted target still exists, is not accepted again if
that target's table is rejected later. A deleted target may name a table that no longer exists. Whether a
target table is visible from its reader, and whether a bound operand's text
names its target's current coordinate, are formula-grammar rules checked by
the calculator, not by this format.

**Populated cells** are cell records with non-empty source plus rule-column
cells without a record. The provisional ceiling of 4,000 applies to the sum
over all tables in one sheet. Exceeding it, or the source byte limit, withholds
every table projection; nothing is truncated.

## Canonical serialization

The writer emits blocks only for deliberately created, duplicated or repaired
tables. It never mints identities: new IDs come only from explicit creation,
duplication or repair (`TableModel.creating`, `TableIdentity.mint()`), never
from parsing or writing. It validates the model first and emits:

```text
@ganit-table 1<EOL>
<payload><EOL>
@end-ganit-table<EOL>
```

`<EOL>` is the chosen terminator (`\n` by default, or `\r\n` or `\r`). The
payload is one line of compact JSON with no insignificant whitespace:

- Root keys in the order `ids`, `t`, `n`, `c`, `r`, `x`, `b`; `t` is always `0`.
- Column keys `i`, `h`, `p`, then present optional keys `u`, `m`, `f`, `z`.
- Cell keys `a`, `s`, then `"o":true` for overrides.
- Ledger keys `o`, `f`, `e`; binding keys `i` (when present), `k`, `a`, `t`,
  `l` (when the kind has locks), then `"d":true` for deleted bindings.
- Cell records in row-major order (row order, then column order). Ledger
  entries with rules first in column order, then cells in row-major order.
- Dictionary entries in first-use order: the table, columns, rows, then each
  binding's ID and target identities in ledger order.
- Strings escape `"` and `\` with a backslash; `\b`, `\f`, `\n`, `\r` and
  `\t` use their short escapes; every other C0 control (U+0000–U+001F), every
  C1 control and U+007F (U+007F–U+009F), and U+2028 and U+2029 use lowercase
  `\uxxxx`. Everything else, including `/` and other non-ASCII text, is
  literal UTF-8.

Readers accept any valid spelling; canonical form only makes new blocks
deterministic. Existing blocks are never decoded and re-encoded: edits replace
or append individual JSON values with an optimistic check of the expected
bytes (`TableSourcePatch`). A formula edit must replace its owner's ledger
entry in the same transaction; otherwise the block is stale and has no
projection until it is repaired.

## Example

```text
@ganit-table 1
{"ids":["abcdef00-0000-4000-8000-000000000001","abcdef00-0000-4000-8000-000000000011","abcdef00-0000-4000-8000-000000000012","abcdef00-0000-4000-8000-000000000021","abcdef00-0000-4000-8000-000000000031"],"t":0,"n":"Items","c":[{"i":1,"h":"Qty","p":"value","u":"kg"},{"i":2,"h":"Total","p":"value","f":"=[@Qty] * 2","z":"sum"}],"r":[3],"x":[{"a":[3,1],"s":"2"}],"b":[{"o":[null,2],"f":"=[@Qty] * 2","e":[{"i":4,"k":"current","a":[1,7],"t":[1]}]}]}
@end-ganit-table
```

## Size

The canonical block (delimiters and LF terminators included) of a table named
`Big` with one value column `A` and 4,000 rows, where row *n* (header row 1)
holds `=A{n+1} + 1` bound as a `cell` binding to the next row and the last row
holds `=1`, is 641,479 bytes; `documentedCeilingSizeIsReproducible` asserts it.
The same chain with 10,000 rows exceeds the 1 MiB source limit. The
source byte limit remains an independent and often tighter gate for long text,
long formulas or many references.
