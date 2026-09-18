# Audit fixes for 0.4.0

Work proceeds in audit order on `main`; each item is reviewed, tested, committed,
and pushed before starting the next. Release 0.4.0 follows all fifteen fixes.

G01 full GitHub CI passed (run 35338124822).
G02 full GitHub CI passed (run 35338582291).
G03 full GitHub CI passed (run 35339073557).
G04 full GitHub CI passed (run 35339826684).

## G01 — Undo and reference renumbering

- Reproduced with a real window and normal event grouping: typing `5` before
  `10`, then Return, then Undo restored the reference without removing Return.
- End typing coalescence and open an Undo group before a line-changing edit;
  close it after all automatic reference rewrites. Undo/Redo restore both edits.
- Reviewed the diff for Undo/Redo guards, nested notifications, existing explicit
  Undo groups, and scope. No grammar or storage format changed.
- Validation: 479 package tests pass, including typing/Return, paste, deletion,
  multiple-reference Undo/Redo, editor commands, and scrubbing. Formatting,
  attribution, pseudolocalized layout, debug app build, bundle verification,
  and `git diff --check` pass. Remaining CI checks run after pushing.

## G02 — Export assisted display-answer provenance

- Added an explicit export status (none, calculated, ai-unverified, failure,
  pending) instead of inferring origin from the answer text or color.
- CSV writes Status beside the unchanged readable Answer. HTML and the shared
  PDF/print view annotate assisted answers; Copy with Results uses the same
  localized annotation. Pending requests are exported as pending.
- Regression coverage checks the editor's actual assisted answer, CSV status,
  HTML/print annotations, and copied text. G07 will address the separate
  computable `ask_assistant` path and dependency provenance.
- Validation: 480 package tests, formatting, pseudolocalized layout, debug app
  build, bundle verification, and diff whitespace checks pass.

## G03 — Complete selection summaries

- Count selected calculations, calculated values, failed calculations, and
  pending calculations. Non-calculation lines do not contribute.
- Mark unresolved selections Incomplete and suppress Total/Average. Show the
  bar even for selections containing only failures. Reject stale edited-line
  answers until their evaluation completes.
- Refresh summaries at assistant request start and completion as well as
  selection/evaluation changes. No implicit acceptance of AI display answers.
- Reviewed classification, partial-line selection, incompatible values, and
  empty selections. Validation: 483 package tests, formatting, pseudolocalized
  layout, debug app build, bundle verification, and diff whitespace checks pass.

## G04 — Disclose correction lifetime and offer durable source

- Chose the audit's explicit temporary-lifetime/save-value option rather than
  adding a new answer storage format or saving stale model replies.
- Change Answer warns that temporary corrections disappear on quit. Its default
  action saves a validated single-line value into source and retains the original
  line in a manual-answer comment; Use Temporarily remains an explicit choice.
- Reviewed validation, session-cache independence, Undo isolation, source-change
  persistence, and no network calls. Invalid or assistant-dependent input cannot
  edit the sheet. Reopening saved source calculates without an assistant and
  dependent formulas use the value.
- Validation: 485 package tests, formatting, pseudolocalized layout, debug app
  build, bundle verification, and whitespace checks pass.

## G05 — Bound interpretation cards

- Bound the card to 560×600 points or the usable screen area minus margins.
  Explanations wrap, long values use a 96-point selectable scroll field, and
  Copy Full Precision stays outside the scrolling details.
- The audited mortgage regression covers normal and compact screen sizes,
  actual card bounds, usable scroll-document dimensions, and exact copying.
- Reviewed the live built app through Computer Use. This caught a zero-width
  scroll field missed by the first layout checks; added a regression and fixed
  the field width. Relaunched the corrected bundle and confirmed visible exact
  digits, readable result, finance assumption, and Copy Full Precision button.
- Validation: 486 package tests, formatting, pseudolocalized layout, debug app
  build, bundle verification, and whitespace checks pass.

## G06 — Cancel assistant requests

- Stop now cancels evaluation and every assistant request of the sheet; a new
  Cancel Request command (answer menu and Calculate menu) cancels only the
  selected line or prompt. Each request keeps its task handle.
- Cancelled lines and prompts show their diagnostic, ignore a late reply, and
  are not asked about again until Ask Assistant. Docs state that cancelling
  cannot recall a line already sent.
- Review found that a temporary correction made while a request was pending
  could be overwritten by the late reply; cancelling the request fixes it.
- Validation: assistant regression tests cover Stop for line and prompt
  requests, no automatic re-asking, Ask Assistant retry, per-line Cancel
  Request, and late-reply suppression. 489 package tests, formatting,
  pseudolocalized layout, debug app build, bundle verification, and
  whitespace checks pass.

## G07 — Explain unreferenceable AI display answers

- Kept the deliberate distinction: line-level answers stay display-only and
  `ask_assistant` stays the computable path. G04's reviewed Save Value into
  Sheet is the explicit accept-as-value action, so no second one was added.
- A reference failing because its target shows an AI display answer now says
  so and points to Change Answer…; ordinary failed references are unchanged.
  The interpretation card lists the AI answer and how to make it a value.
- Answer cells are redrawn when an assistant answer changes, so dependent lines
  update without re-evaluation.
- Validation: regression covers the dependent diagnostic, an unaffected
  ordinary failure, the card rows, and dependents calculating after saving.
  490 package tests, formatting, pseudolocalized layout, debug app build,
  bundle verification, and whitespace checks pass.

## G08 — Keep meaning in narrow answer columns

- A value wider than the column is drawn from a six-significant-digit form
  marked `≈`, which keeps its unit; rounding is therefore marked, distinct from
  truncation. Anything still too wide is middle-truncated for values (keeping
  unit or zone) and tail-truncated for messages.
- Hover still shows the full answer and Show Interpretation the full message,
  so no separate diagnostic titles or column-resize control were added.
- Validation: regression checks the full text in a wide window, `≈ 142.857 mA`
  at 320 points, no compact forms for short answers or failures, truncation
  modes, and the hover text. 491 package tests, formatting, pseudolocalized
  layout, debug app build, bundle verification, and whitespace checks pass.

## G09 — Mark rounded displays and export exact values

- `FormattedResult.isRounded` records when an exact value's display dropped
  digits (significant-digit rounding, fixed decimals, or scientific), and the
  display is marked `≈`, following money's existing marker. Hexadecimal,
  binary, fraction, and terminating values stay unmarked; the value remains
  exact and is not labelled approximate.
- The interpretation card's Exactness says "Exact; shown rounded by Format ▸
  Number Format", making the rounding setting discoverable where it matters.
- CSV gains a Full Precision column beside the readable Answer.
- Seventeen golden-corpus displays gained the marker; no value, full
  precision, or status changed. The grammar is unchanged, so the ambiguity
  registry is not bumped. The recorded Numi comparison is left as history.
- Validation: formatter, display-option, corpus, CSV, and editor regressions
  cover marked and unmarked cases, the card wording, and exported full
  precision. 492 package tests, the ASan corpus, formatting, pseudolocalized
  layout, debug app build, bundle verification, and whitespace checks pass.

## G10 — Label AI answers in text

- Assisted answers draw an outlined "AI" badge before the value; layout
  reserves its width so the value never overlaps it and narrow columns shorten
  the value instead. Selection recolours the badge with the answer.
- Hover explains "AI answer, unverified. Formulas cannot use it." and the
  answer's accessibility element is labelled "Line N AI answer, unverified";
  copying and exports already carry the annotation from G02.
- Reviewed a rendered sheet at normal and narrow widths; the badge, the G07
  dependent message, and the G08 compact value all display as intended.
  VoiceOver listening remains a manual check.
- Validation: regression covers badge width in layout, hover text, the
  accessibility label, and no badge on calculated answers. 493 package tests,
  formatting, pseudolocalized layout, debug app build, bundle verification,
  and whitespace checks pass.

## G11 — Per-sheet decimal comma

- Format ▸ Decimal Comma (1.234,56) toggles the sheet's stored locale between
  `en-US` and `en-DE` (English words, German separators); the engine already
  lexed comma decimals with `;` or `, ` argument separators. Two styles cover
  the audit's cases without inventing space grouping.
- New sheets are seeded from the Mac region's decimal separator; imports,
  recovery, and Quick Ganit keep the standard `en-US` preferences.
- A syntax failure whose expression parses only with the other style is
  diagnosed as written in that style, suggests the expression with `.` and `,`
  swapped when that parses, and is never sent to the assistant.
- Validation: store, editor, and workspace regressions cover region seeding,
  lexing from preferences, persisted toggling with recalculated answers, the
  diagnostic and suggestions, and no assistant request. 496 package tests,
  formatting, pseudolocalized layout, debug app build, bundle verification,
  and whitespace checks pass.

## G12 — Line numbers and Go to Line

- View ▸ Show Line Numbers, stored in the sheet's display options beside the
  answer separator, draws physical line numbers in a gutter; wrapped rows
  share one number and blank lines are counted, as `line N` counts them.
  The source moves right by overriding `textContainerOrigin`; the answer
  column keeps its right edge.
- Edit ▸ Go to Line… (⌘L) selects the start of a line, scrolls to it, and
  flashes it; out-of-range numbers beep. Reference-target highlighting was
  not added; numbered lines and Go to Line cover the navigation gap.
- Reviewed renders at a narrow width and the live debug app: numbers align
  to the source baseline, and clicking beside the gutter puts the caret at
  the start of the clicked line. The QA sheet's setting was turned back off.
- Validation: regression covers the gutter offset, numbering with a wrapped
  line and blank line, unchanged answer column, and Go to Line bounds. 497
  package tests, formatting, pseudolocalized layout, debug app build, bundle
  verification, and whitespace checks pass.

## G13 — Per-answer number format

- Added an Answer Format submenu to the answer context menu: Sheet Default
  plus the sheet's number formats, with the current choice checked. Only
  calculated answers enable it.
- Overrides live in `DisplayOptions.answerFormats`, keyed by the line's
  trimmed text; no grammar or storage schema version changed. Editing the
  line returns it to the sheet format; moving it keeps the choice.
- The editor reports its own display-option changes, and the workspace saves
  them with the sheet. Interpretation and export use the line's formatter.
  The shared format list moved into `GanitEditorUI` to serve both menus.
- Validation: editor and workspace regressions cover checked states, one line
  changing while an equal-valued line does not, reset, and persistence. 499
  package tests (after a clean rebuild for the layout change), formatting,
  pseudolocalized layout, debug app build, bundle verification, and
  whitespace checks pass.

## G14 — Show Quick Ganit's copy-and-close action

- Added a "⌘↩ Copy Result and Close" title-bar button beside Keep as Sheet; it
  performs the same action as ⌘Return. Its tooltip distinguishes it from Keep
  as Sheet, and without a result it briefly reads "No Result to Copy" instead
  of only beeping.
- Reviewed the live debug panel: both buttons fit the title bar without
  overlap. The regression test sends the button's action rather than
  `performClick`, whose nested run loop ends Swift Testing's main executor
  when UI tests interleave.
- Validation: regression covers the title, tooltip, the no-result message
  with the panel staying open, and copying and closing with a result. 500
  package tests, formatting, pseudolocalized layout, debug app build, bundle
  verification, and whitespace checks pass.

## G15 — Diagnose a trailing equals sign

- A declaration-shaped line with nothing after `=` whose left side contains a
  number or operator and parses as an expression now reports the new
  `trailingEquals` syntax code on the `=`: answers appear on their own, remove
  it, or use `=>` before a note. Word-only names such as `Groceries (Costco) =`
  and non-empty declarations keep their existing name diagnostics.
- Such lines are not sent to the assistant. No grammar acceptance changed, so
  the ambiguity registry is untouched.
- Validation: sheet regression covers the trailing forms, spacing, the `=`
  range, preserved name diagnostics, and `=>`. 501 package tests, the ASan
  corpus, formatting, pseudolocalized layout, debug app build, bundle
  verification, and whitespace checks pass.

## Remaining

Release validation, version bump, and publication via the existing
signed/notarized GitHub release workflow triggered by `v0.4.0`.
