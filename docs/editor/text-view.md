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
is never inserted into the text storage. The overlay also draws a dim rule down
the middle of the gap, which **View ▸ Show Answer Separator** hides.

A sheet whose display options ask for answers inline — **Format ▸ Markdown Mode** —
gives the source the full width and writes each answer a gap past where its own
line's last row of text ends, in the secondary label color, so a sheet reads as
prose with its arithmetic annotated rather than as two columns. There is no
column then, and so no rule.

New workspace sheets use an `en-US` context with the current time zone until
sheet locale preferences exist. Each evaluation generation freezes `now` at the
moment it starts. When an answer read the clock, the scheduler sleeps once until
the earliest moment one can change — the next second for `now`, the next
midnight in the context's zone for `today` — and evaluates again, reusing every
line that did not read the clock. Sheets without such answers never wake.

## Decoration

Decoration never changes the text storage. For each line of the newest shown
evaluation whose text still matches the editor, `LineDecoration` derives runs
from the line's role and result, in UTF-16 ranges relative to the line:

| Run | Style |
|---|---|
| comment, label | secondary label color |
| divider, heading `#` marker | tertiary label color |
| heading title | semibold |
| markdown `**bold**` / `*italic*` | bold / italic |
| error diagnostic or evaluation-error range | dotted red underline |
| warning or ambiguity | dotted orange underline |

Incomplete input, such as `2 +`, is underlined only after the insertion point
leaves its line. An empty diagnostic range underlines the preceding character.

Colors are TextKit 2 rendering attributes, which move with edits but are not
part of the source. TextKit 2 does not draw underline rendering attributes, so
the answer overlay draws underlines from text-segment geometry, just below the
baseline. A line is redecorated only when its decoration changes or it was
edited since, because edits and undo can leave inserted text without rendering
attributes; an edited line's underlines are removed immediately so they never
drift onto new text.

## Answers, errors, and interpretation

The answer column shows a line's formatted result. When a line's decoration
flags a failure, the column shows its concise localized message in red instead;
the message text is the non-color cue. Incomplete input therefore shows its
message only after the insertion point leaves the line. A line waiting on an
assistant shows Asking… until a value arrives.

| Interaction | Effect |
|---|---|
| Click an answer | Selects it; Copy copies the displayed answer |
| Double-click an answer above the insertion point | Inserts `line N` at the insertion point |
| Option-double-click an answer | Copies the displayed answer |
| Space on a selected answer | Opens its interpretation card |
| Hover a function, keyword, or error | Shows its signature or message |
| Hover a cut-off answer or error | Shows the full text |
| Right-click a function or keyword | Help for that name |
| Right-click Ask Assistant | Asks again about a line Ganit could not work out, or an `ask_assistant` prompt |
| Right-click Change Answer… | Replaces an assistant value on that line |
| Right-click Copy with Results | Copies each selected line with the answer it shows |
| Escape or typing | Clears the answer selection |

Function and keyword names complete while typing. The list shows each
function with its parameters. Tab or a click inserts the selected completion
and selects the first parameter; Tab then moves to the next one. Return
inserts it only after an arrow key picks a row, so a line ending in a word such
as `min` or `m` still ends with Return.
Escape dismisses the list. **Edit ▸ Autocomplete** turns the list off.

`copyResult:`, `copyFullPrecision:`, `copyLinesWithResults:`,
`showInterpretation:`, `askAssistant:`, and `changeAssistantAnswer:` are
responder actions that act on the selected answer or, without one, the
insertion point's line, so menus and keyboard shortcuts can reach them. Copy
Result copies a failure's message when that is what the column shows. Copy with
Results copies each selected line with that answer after a tab. Ask
Assistant is enabled for a flagged line or an `ask_assistant` prompt when an
assistant is set up, and asks again even if that text was already sent. Change
Answer… is enabled when that line already has an assistant value.

Source and answers together stop widening once a window is wider than a sheet
needs, so an answer stays beside its line instead of at the far edge of a large
display; the rest of the window is margin.

The interpretation card is a transient popover listing the expression, result,
full precision, value kind, and exactness, then one Assumption row for each
[finance function](../grammar/finance-functions.md) the answer used; for a
failure it lists the expression, the underlined text the problem is at
(Where), the message, and any suggestions. Unit conversions, provenance,
time zones, and references join the card as those details become available.

## Selection summary

A bar below the sheet shows what the selected lines add up to: the number of
answers the selection covers, and their total and average. It appears only
while a selection covers more than one answer, because a single answer is
already beside its line, and it takes the editor's bottom edge while it is
there.

A line contributes its answer when the selection reaches any part of it, so a
selection dragged partway through the first and last lines still counts them.
Lines without an answer — blank lines, headings, comments, labels, and
failures — contribute nothing. Totals and averages follow the same rules as a
[`total` line](../grammar/references.md), so answers that cannot be added,
such as money and metres, leave the bar showing their count alone.

The bar is static text labeled "Selection summary" for accessibility, with no
action of its own; a sheet's own `total`, `average`, and `subtotal` lines
remain the way to keep a sum.

## Scrubbing a number

Holding Option over a number in a line turns the pointer into a left-right
arrow, and dragging sideways steps the number while every answer that depends on
it follows. A step is one unit of the place the number was written to, so `2.50`
moves by hundredths and `2,100` by ones; Shift steps ten of that place at a time
and Command a tenth of it, which adds a decimal the number did not have. A drag
counts from where it started rather than from what its last step wrote, so
dragging back returns the number it began with, and the whole drag undoes as one
change named "Change Number".

Step Number Up ⌃↑ and Step Number Down ⌃↓ do the same to the number at the
insertion point, so the feature is not one only a pointer can reach; the
insertion point stays in the number so it can be stepped again. Both are
disabled when no number is there.

Scrubbing changes the digits a person points at, which is why it works on the
literal the lexer found rather than on the value a line computes. Dragging right
raises those digits and dragging left lowers them, stopping at zero, because a
sign in front of a number belongs to the expression. A number written as a power
of ten, or in hexadecimal, binary, or octal, is left alone: stepping it would
have to guess how the result should be written.

## Text size, appearance, and accessibility

View ▸ Bigger, Smaller, and Actual Size step the editor's text scale through
75%, 100%, 125%, 150%, 175%, 200%, 250%, and 300% of 14 pt. Source text,
answers, and the answer column's width bounds scale together.

All editor colors are semantic system colors resolved at draw time, so Light
and Dark appearances, accent colors, and Increase Contrast apply without
Ganit-specific palettes; the overlay redraws when the effective appearance or
accessibility display options change. With Increase Contrast, failure
underlines are thicker. The editor has no animation and no custom material, so
Reduce Motion and Reduce Transparency need no special handling.

For accessibility, the text view appends one static-text element per visible
answer to its children, labeled "Line N result" or "Line N error" with the
answer or message as its value and its on-screen frame. Custom actions offer
Copy Result, Copy Full Precision, Show Interpretation, Ask Assistant, and Insert
Reference, so every mouse interaction with answers has a VoiceOver and keyboard
equivalent.
Answers are not announced as they change while typing.

## Latency instrumentation

`SignpostedInterval` (in `GanitDiagnostics`) emits Points of Interest signposts
without metadata, so no sheet text reaches logs or Instruments:

- `EditToAnswer` begins when an edit schedules a generation and ends after the
  answer overlay draws that generation. Superseded or stopped generations end
  it as cancelled.
- `Evaluation` covers incremental evaluation on the worker actor.
- `AnswerLayout` covers the overlay's layout and drawing of visible answers and
  underlines.

The controller's `editToAnswerHandler` receives each drawn generation's
edit-to-answer duration; `GanitBenchmarks --editor` uses it to measure the
Section 8 keystroke-to-answer gates.

To keep that path short, committing a generation does no per-line formatting:
answer cells are computed only for drawn lines and cached by result, and only
lines whose text, role, or failure state changed are redecorated.

## Problem and result navigation

**Calculate ▸ Next Problem** (⌘') and **Previous Problem** (⇧⌘') move the
insertion point to the start of the next or previous line whose answer is a
failure, wrapping around, and ask VoiceOver to announce it as
`Line 3: This identifier is not defined.` The commands are disabled when no
line has a problem and beep if the answers change before they run.

The text view offers two VoiceOver rotors, **Problems** and **Results**. Each
item selects its whole line and is labeled with the line number and answer
text, so VoiceOver users can move between errors or results without reading
every line. Answers are otherwise never announced while typing.
