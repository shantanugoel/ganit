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

## Evaluation and answers

After a committed edit, the controller schedules evaluation of the current
`SheetSource` snapshot. While IME composition has marked text, it waits; the
commit schedules the generation. `SheetEvaluationScheduler` runs
`SheetCalculator` on a worker actor that owns the incremental cache, cancels
the running generation when a newer snapshot arrives, and commits only the
newest request's evaluation to the main actor.

Answers are formatted with `ResultFormatter` using the sheet's context and
cached per line until the line's value changes. Lines without a value, including
incomplete and failing lines, show no answer.

`SheetTextView` narrows its text container to leave a right-hand answer column
(35% of the width, clamped to 140–360 pt, with a 16 pt gap) so source wraps
before it. A click-through overlay view above TextKit 2's text layout views
draws each answer right-aligned, with tabular digits, on the first row of its
line's layout fragment, and truncates it when it exceeds the column. Answer text
is never inserted into the text storage.

New workspace sheets use an `en-US` context with the current time zone until
sheet locale preferences exist, and `now` is fixed when the sheet opens because
no expression depends on it before dates are added.
