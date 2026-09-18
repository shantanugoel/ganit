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
  Request, and late-reply suppression. 492 package tests, formatting,
  pseudolocalized layout, debug app build, bundle verification, and
  whitespace checks pass.

## Remaining

G07–G15, then release validation, version bump, and publication via the existing
signed/notarized GitHub release workflow triggered by `v0.4.0`.
