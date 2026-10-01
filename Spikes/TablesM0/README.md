# Disposable calculation-table M0 spikes

This executable is isolated from all shipping targets. Run from the repository:

```sh
swift run GanitTablesM0 --native --fixtures Spikes/TablesM0/Fixtures
swift run -c release GanitTablesM0 --native
swift run GanitTablesM0 --native --snapshot /tmp/ganit-table-preview.png
swift run GanitTablesM0 --show
```

`--show` opens the native prototype; terminate the executable after reviewing.
The left pane is a derived inline preview; the right pane is an editable native
three-row grid. Press Return in a grid field to commit into canonical source
through the existing sheet editor's document UndoManager. Return to Sheet
reveals canonical source. This deliberately exposes the source for inspection,
rather than claiming to implement the production expanded/return interaction.
No app preference, library document, or schema is changed.

The executable verifies raw blocks with Unicode and CR/LF/CRLF; invalid/unknown
block quarantine; stale/duplicate/conflicting binding rejection; distinct
owners with identical formulas; deleted target markers and reload; iterative
SCC cycles and blocked readers alongside valid components; exact Ganit decimal
arithmetic; a 10,000-node chain; verbose/compact source byte overhead; and native
source edits, Undo/redo, autosave callbacks, copy and focus checks.

`SourceSpike` uses intentionally verbose pretty-printed JSON. `CompactSpike`
proves a block-local identity dictionary with source-string fingerprints.
`GraphSpike` sums already typed Ganit values; it is neither a formula parser
nor a production incremental calculator. `ProjectionSpike` demonstrates source
mapping and read-only layout, with fixed fixture formatting/divider geometry.
`NativeSpike` patches a whole experimental block through the current editor;
production must extract a document coordinator and patch only changed spans.

The fixture's below-table expression is illustrative source, not integrated
mixed-sheet evaluation. Real grammar, inherited closures, downstream table
operands, structural transforms, column templates, native Find UI and complete
accessibility tasks remain the work of M1–M6. Nothing here should be moved
wholesale into a shipping module. Remove this target when production tests
supersede its proofs.

See [evidence](evidence.md), [semantics/editor ADR](../../docs/adr/0016-table-semantics-and-editor-ownership.md)
and [source/storage ADR](../../docs/adr/0017-table-source-and-storage-compatibility.md).
