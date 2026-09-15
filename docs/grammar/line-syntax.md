# Line syntax

A sheet is segmented into lines (see
[sheet source](../engine/sheet-source.md)), and each line has exactly one
structural role. Prose is recognized only through the explicit markers below;
any other text is an expression and unknown words are reported, not skipped.

| Role | Form | Example |
|---|---|---|
| Blank | empty or whitespace only | |
| Divider | three or more `-` and nothing else | `---` |
| Heading | first non-space character is `#` | `# Trip budget` |
| Comment | first non-space characters are `//` | `// assumptions` |
| Calculation | optional `label:`, optional `name =`, optional expression, optional `// comment` | `Rent: monthly rent = 2,100 // shared` |

Rules, applied in this order:

1. Headings take the whole line; `#` is not part of the title, and `//` inside
   a heading is title text.
2. The first `//` starts a comment that runs to the end of the line.
3. Before any comment, the first `:` followed by whitespace or the end of the
   remaining text ends a label, provided the label is not empty. A colon
   without following whitespace, such as `10:30`, stays in the expression.
4. In the remaining text, the first `=` with a non-empty name before it makes
   a [variable declaration](variables.md).
5. The remaining trimmed text is the expression. `Groceries:` is a label with
   no expression and produces no result; `total =` is an incomplete
   declaration.

Dividers must contain only hyphens, so `---5` is still arithmetic. Line roles
carry exact ranges for labels, expressions, titles, and comments, relative to
the start of the line, so the editor can decorate them without changing source
offsets.

## Sections

Blank lines, headings, and dividers are the structural boundaries of a sheet.
A blank line separates implicit blocks; a heading or divider starts an explicit
section. [References and aggregates](references.md) read the current block, and
a divider also resets [variable](variables.md) scope.

## Evaluation

`SheetCalculator` evaluates a `SheetSource` and returns one `SheetLineResult`
per line, in order, with the line ID and role. Only lines with an expression
have a result. Lines are evaluated top to bottom, so a line sees the
declarations above it. The expression is parsed from its offset within the
line, so every token, AST, diagnostic, and evaluation-error range is relative
to the start of the line's text; add the line's `range` for sheet offsets. See
[incremental evaluation](../engine/incremental-evaluation.md).
