# Table references

A calculation table is a named block of rows and columns. A formula inside a
table reads other cells of the same table. Prose below the table reads table
values with a qualified reference. This page is the public grammar. The exact
rules are in [ADR 0016](../adr/0016-table-semantics-and-editor-ownership.md);
the block format is in [table blocks](../storage/table-blocks.md).

## Addresses inside a table

The header row is row 1. The first data row is row 2. Column letters are
ASCII letters, case-insensitive.

| Form | Meaning |
| --- | --- |
| `=B2 * C2` | cells of the current table |
| `=$B$2`, `=$B2`, `=B$2` | locks for copy and fill: both axes, the column, or the row |
| `=sum(B2:D6)` | a rectangle of cells |
| `=sum(C:C)` | the whole data column, without the header and totals |
| `=sum(2:2)` | the whole data row, including the formula cell if it is in it |
| `=[@Qty] * [@[Unit price]]` | the current row's named columns |
| `=sum(Items[Amount])` | the data-only values of one named column |

Rules:

- An address outside the table fails. There is no cell past the last row or
  column.
- A whole row or column that includes the formula cell is a cycle. Ganit does
  not remove the formula cell from its own range.
- Headers return text. A header is literal text, so spaces, currency names,
  and unit words in a header are never read as variables or units.
- Inside header brackets, `\]` is a literal `]` and `\\` is a literal
  backslash. An unknown escape fails.

## Other tables and inherited names

| Form | Meaning |
| --- | --- |
| `=Rates!B2`, `=sum(Rates!B2:B8)` | a cell or range of a table visible above |
| `=sheet[B2]` | an ordinary variable named `B2` from the sheet scope |
| `cost = sum(Items[Amount])` | a prose line that reads a table column |

Rules:

- A table reference can only name a table visible above the line. Dividers
  reset that visibility, and references to later tables fail.
- A table name with spaces or punctuation uses backticks:
  `` `Travel costs`!B2 ``. Two backticks in a row are a literal backtick.
- `sheet` is reserved as a table name for the sheet-scope qualifier. Outside
  table formulas, a bare `B2` stays an ordinary variable.
- Bare aggregate words and `previous` fail inside table formulas. Write an
  explicit range, such as `sum(B2:B6)`. To use an inherited variable named
  `count`, write `sheet[count]`.
- Function names are case-insensitive inside table formulas: `SUM` and `sum`
  are the same function.

## Broken references

A deleted target stays broken in source as `#REF!{...}`. Its old address
cannot repair it: reuse of a coordinate does not rebind a broken reference.
Use Repair Broken Reference in Table Actions to select the broken operand,
pick a new target, and commit. The repair survives save, reload, and undo.

## Values, ranges, and totals

- `sum`, `total`, `average`, `median`, `min`, `max`, and `count` read one
  range. They skip blank and text cells, and a failed cell fails the result.
  `count` counts nonblank values, so `count(range)` over text is 0.
- An empty range gives `sum` 0, and gives `average`, `median`, `min`, and
  `max` an error.
- A column total is a footer summary, not a data row. Prose reads the same
  values with its own aggregate, such as `sum(Items[Amount])`.

## What a table line does not do

A table's source lines have no scalar answers. `line N` and `@N` cannot name
a line inside a table; they fail and point to the table's qualified
references instead. Table cells never join bare `sum` or `previous` in prose.
See [references](references.md) for ordinary line references and see
[Calculation tables](../editor/tables.md) for the editor commands.