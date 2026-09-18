# Audit fixes for 0.4.0

Work proceeds in audit order on `main`; each item is reviewed, tested, committed,
and pushed before starting the next. Release 0.4.0 follows all fifteen fixes.

G01 full GitHub CI passed (run 35338124822).
G02 full GitHub CI passed (run 35338582291).

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

## Remaining

G05–G15, then release validation, version bump, and publication via the existing
signed/notarized GitHub release workflow triggered by `v0.4.0`.
