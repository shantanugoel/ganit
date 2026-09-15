# Sheet source and line identity

`SheetSource` segments a sheet into logical lines before lexing. Line
terminators match the lexer: `\n`, `\r\n`, and `\r`. Every source has at least
one line, and only the final line lacks a terminator. Each line keeps its exact
terminator, so `SheetSource.text` reproduces the original source byte for byte.

A `SheetLine` carries its text, terminator, and the `SourceRange` of its text
in sheet UTF-8 and grapheme coordinates. Diagnostics produced for a line's text
can therefore be offset into sheet coordinates without reparsing.

## Stable IDs

Each line has a `LineID` that is independent of its current line number. IDs
are session identities for incremental evaluation; they are not persisted in
source text and are never reused within one `SheetSource`.

`replace(utf8Range:with:)` applies an editor edit given in sheet UTF-8 offsets
on Unicode scalar boundaries. It resegments only the touched lines, including
the previous line when an edit starts at a line boundary so `\r` followed by
an inserted `\n` becomes one terminator. Later lines only have their ranges
shifted. Within the touched span:

1. Leading lines whose text is unchanged keep their IDs.
2. Trailing lines whose text is unchanged keep their IDs.
3. Remaining old IDs are reused in order.
4. Any additional lines receive new IDs.

Thus typing within a line keeps its ID, pressing Return keeps the ID of the
content that did not move, and joining two lines keeps the first line's ID.
