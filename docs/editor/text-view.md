# Sheet text view

`SheetEditorViewController` (in `GanitEditorUI`) hosts sheet source in a
standard scrollable `NSTextView`, which owns selection, marked text and IME
composition, bidirectional layout, Find, and responder-chain commands. Ganit
does not reimplement any of them.

Configuration:

- Plain text only: rich text and graphics import are off.
- System font at 14 pt with natural base writing direction, so right-to-left
  lines lay out by their content.
- The Find bar with incremental search is on.
- Automatic quote, dash, and text replacement, spelling correction, continuous
  spell and grammar checking, data and link detection, and smart insert/delete
  are off. Each would silently change calculation source, for example `--` into
  an em dash.
- Undo is enabled and uses the controller's `documentUndoManager`, not the
  window's, so every sheet keeps its own history.
- The controller makes the text view first responder when its view appears.

The text storage is the only editable copy of the source. After each committed
character edit (`NSTextStorageDelegate.didProcessEditing`), the controller
converts the edit's UTF-16 range to UTF-8 offsets and applies it to its
`SheetSource`, so line IDs follow edits exactly as described in
[sheet source](../engine/sheet-source.md). Marked text is part of the text
storage and is mirrored too; deciding when composition has committed belongs to
evaluation scheduling.
