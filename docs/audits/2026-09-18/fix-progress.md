# Audit fixes for 0.4.0

Work proceeds in audit order on `main`; each item is reviewed, tested, committed,
and pushed before starting the next. Release 0.4.0 follows all fifteen fixes.

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

## Remaining

G02–G15, then release validation, version bump, and publication via the existing
signed/notarized GitHub release workflow triggered by `v0.4.0`.
