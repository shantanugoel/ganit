# M5 inline preview test report

Date: 2026-10-04. Branch: `tables`. Worktree:
`/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`.
Starting commit: `3f2b97f85cc997dc0ecebdd871dd0b1e4b223a8a`.

## Task commits

Each task had a basic check before its commit.

| Task | Commit | Basic check |
|---|---|---|
| 1. Mapped inline preview with reserved layout | `691c2ca` | Debug build |
| 2. Insert Table controls and Paste as Table | `7addc0b` | Debug build |
| 3. Values, totals, Pending and cell inspection | `d17adb4` | Debug build |
| 4. Find mapping, source inspection, printing | `6c54d8e` | Debug build |
| 5. Atomic preview edits and Writing Tools policy | `9e06172` | Focused tests |

## Review corrections

Commit `a9c6ab5` contains the review corrections and regression tests.

The phase review found these defects. Each correction has regression tests.

- Preview edit protection blocked the automatic update of table references
  when prose lines moved. The protection now permits controlled rewrites.
- A diagnostic click changed the diagnostic selection. A find selection now
  opens a table only when the table changes, and never during cell edits.
- Number columns in a narrow preview kept their fixed width. Columns now
  share the scroll width and relayout when the text scale changes.
- Preview controls were absent from the accessibility tree. The title, the
  Open Table button, the cell area, the totals and the inspection line are
  now accessibility elements with roles.
- Native Find-bar buttons do not call the text view, so mapped Find results
  never opened a cell. A mapped `NSTextFinder` client now owns the find-bar
  session. It selects each match and opens the mapped expanded cell.
- Source retention tests edited raw block source by accident. These tests
  now enter the explicit source inspection mode first.
- Writing Tools could start in the expanded formula field. The field now
  disables Writing Tools.
- Typing attributes kept table preview fonts after layout. The view now
  resets its typing attributes after each preview layout.

## Automated checks

The full suite passed 1,070 tests in 132 suites with no failures. The new
inline-table suite has 15 tests. It covers source mapping and reserved
space, cross-boundary copy, one-Undo rectangle insert, rejected paste,
native find navigation with the real find bar, narrow and scaled preview
layout, accessibility children, marked prose input, preview edits,
structural commands, diagnostic selection and Writing Tools.

The changed files pass the pinned formatter. A repository-wide lint run
reports style findings from the current toolchain in files that this phase
did not change. This phase adds no new lint findings. The debug app build,
the QA app bundle and code signature passed.

Log paths:

- `/tmp/ganit-m5-full-final.log`
- `/tmp/ganit-m5-affected-final.log`
- `/tmp/ganit-m5-inline-final3.log`
- `/tmp/ganit-m5-debug-final.log`

## Native app checks

Computer Use operated the built debug app. A separate QA app identity and
library (`/tmp/GanitM5QA.app`, bundle `com.shantanugoel.Ganit.M5QA`)
kept tests away from existing sheets.

The test sheet had `rate = 3` above the Items table and `cost =
sum(Items[Amount])` below it. Quantities 2, 4 and 6 produced 6, 12 and 18.
These checks passed:

1. The preview shows values, the totals line `Amount sum: 36` and the
   inspection prompt. All preview controls appear in the accessibility
   tree with labels and roles.
2. Click a preview cell. The inspection line shows `C2 · Amount: 6`.
3. Open Table opens the grid with that cell selected and its input in the
   formula field. Return to Sheet restores the sheet.
4. Command-F opens the find bar. Find Next selects the source match and
   opens the expanded table at the mapped cell (Café → A2). Find Previous
   does the same for the RTL match שלום → A4. Typing in the find field
   runs the incremental search and maps the first match.
5. Select all, copy, and paste into a new sheet. The pasted sheet keeps
   the complete canonical block, renders the preview and calculates the
   same totals.
6. Type prose after the table, see the diagnostic, and undo. The edit is
   removed and the preview keeps its layout. Edit a table cell, commit,
   and undo. The cell returns to its prior value with the selection on
   the same row.
7. Command-plus scales the text. The source, the preview controls, the
   cells and the reserved block height all scale. Nothing clips.
8. Markdown Mode answers only lines that end in `=>`. A `=>` line that
   reads the table shows its answer after the arrow. The preview stays in
   place between the prose lines.

## Remaining release checks

Real IME checks, deep VoiceOver listening review, print and PDF output,
export, CLI output modes, usability checks and performance gates belong
to M6. The plan tracks them there.
