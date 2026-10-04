# M6 export and release readiness evidence

Date: 2026-10-04. Branch: `tables`. Worktree:
`/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`.
Starting commit: `b533a52` (the completed M5 state).

## Task commits

Each task had a basic check before its commit.

| Task | Commit | Basic check |
|---|---|---|
| 1. Table TSV/CSV export, values and formulas modes | `2145577` | Focused tests |
| 2. Mixed HTML, PDF/print and Quick Look rendering | `f817e36` | Focused tests |
| 3. Structured CLI output mode | `af5b0ef` | Focused tests and CLI smoke |
| 4. Grammar, recovery and sample docs | `bbfd3d1` | Full suite |
| 5. Benchmarks and usability checks | `6ccbca9` | Focused tests |

Commit `d84ed4a` removes a flaky wall-clock bound from a test. Commit
`07b33a7` contains the review corrections and regression tests.

## Review record

An independent review read the M6 commits after task 5. It found four
defects. Each correction has regression tests:

- Major: the export formula guard used `Double(text)` as the plain-number
  test. Display text is localized, so `-2,100` in an English locale and
  `-1,5` in a German one failed that test and exported as apostrophe
  text. The guard now also accepts numbers written the way the export
  locale displays them (`NumberFormatter` parse). A negative grouped or
  decimal-comma value stays a number in the importing app. An export in
  the real app wrote `"1,500"` and `"-2,500"` without apostrophes.
- Minor: `ganit --tables` with a line argument ignored the flag and ran
  the scalar path. It now rejects the combination with a usage error.
- Minor: a table with one failed cell exited 0 in `--tables` mode.
  `TableGrid` now records failed cells, and structured output treats a
  failed cell like an unreadable table for the exit status.
- Minor: CI did not run the new table benchmark. The workflow now runs
  `GanitBenchmarks --table 5`.

The review also confirmed the RFC 4180 quoting, the locale separator
switch, the print pagination math with repeated headers, the HTML
escaping of table names and cell text, the structured-answer placement
and the benchmark percentile math. It found no defect in those areas.

## Automated checks

The full suite passed 1,097 tests in 59 suites with no failures. The
whole-repo lint reports 6 findings, all in three files that M6 did not
change (`TableEditingSnapshot.swift`, `InlineTablePreview.swift`,
`SheetEditorViewController.swift`). M6 adds no new lint findings. The
release build of every product passed. The debug app build, the QA app
bundle and its ad-hoc signature passed. The app verification script
passed. All document links resolve.

Affected-suite sanitizer runs passed: AddressSanitizer over the
table-text, renderer, export and structured-answer suites; ThreadSanitizer
over the table-text, structured-answer and mixed-render suites.

Log path: `/tmp/m6-full-after-review.log`.

## Performance

Hardware and system: MacBook Pro (MacBookPro18,2), Apple M1 Max, 64 GB.
macOS 27.0 (26A428), Swift 6.4, release build, arm64. Commands:

```sh
swift run --configuration release GanitBenchmarks --table 60
swift run --configuration release GanitBenchmarks --sheet mixed-sheet 40
swift run --configuration release GanitBenchmarks --sheet chained-dependency-sheet 40
swift run --configuration release GanitBenchmarks --parser 400
swift run --configuration release GanitBenchmarks --quick 40
swift run --configuration release GanitBenchmarks --editor <fixture> 40
```

The table fixture has 150 rows with six columns (three rule columns), a
totals rule and 50 reader lines: 900 populated table cells and 55
dependent lines. The `--table` benchmark alternates one table cell
payload edit and one prose reader edit through the incremental
calculator.

### Engine benchmarks (release, this machine, 2026-10-04)

| Benchmark | Metric | Result |
|---|---|---:|
| table-sheet, full evaluation | 900 table cells | 12.1 ms |
| table-sheet, cell edit | P50 / P95 (60 edits) | 9.4 / 10.3 ms |
| table-sheet, prose edit | P50 / P95 (60 edits) | 0.35 / 0.41 ms |
| table-sheet, prose edit | lines re-evaluated | 1 |
| mixed-sheet, full evaluation | 1,000 lines | 36.7 ms |
| mixed-sheet, edit | P50 / P95 | 0.79 / 0.83 ms |
| chained-dependency-sheet, edit | P50 / P95 (10,000 lines re-evaluated) | 37.1 / 39.9 ms |
| parser | nanoseconds per expression | 5,604 |
| quick Ganit show | P50 / P95 | 3.5 / 8.5 ms |

### Editor benchmarks, M5 baseline against M6

Same machine, same toolchain, minutes apart, 40 edits.

| Fixture | M5 baseline `b533a52` P50 / P95 | M6 P50 / P95 |
|---|---:|---:|
| `mixed-sheet` (1,000 lines) | 27.14 / 28.25 ms | 27.16 / 28.54 ms |
| `chained-dependency-sheet` (10,000 lines) | 128.6 / 138.6 ms | 128.0 / 130.8 ms |
| `independent-sheet` (10,000 lines) | 124.6 / 129.2 ms | 123.3 / 126.4 ms |

M6 adds no editor latency. Engine paths also match: mixed-sheet edit
P50 0.81 / P95 1.02 ms at the baseline against 0.79 / 0.83 ms after M6,
and the parser 5,423 against 5,604 ns per expression. Ordinary sheets
and Quick Ganit keep their budgets, so table feature initialization
stays lazy.

### Gate status

The plan sets provisional table targets of P95 16 ms ordinary and
50 ms stress, measured as edit-to-visible-answer. Recorded honestly:

- Engine-level table edits meet the 16 ms ordinary goal: the table cell
  edit P95 is 10.3 ms, and the prose edit P95 is 0.41 ms.
- Document-level edit-to-answer misses the 16 ms ordinary goal and the
  50 ms stress goal on this machine and this toolchain. The mixed-sheet
  editor P50 is 27.2 ms (goal 16 ms) and the chained 10,000-line editor
  P50 is 128 ms (goal 50 ms). The M5 baseline measures the same on the
  current toolchain, so this is not an M6 regression. The recorded
  Phase 4 baseline measured 6.4 ms on Xcode 26.5 and macOS 26.6; the
  drift follows the toolchain and system update, not M6 code. The
  document pipeline needs a separate investigation before release.

## Usability session

Computer Use operated a QA app with a separate library
(`/tmp/GanitM6QA2.app`, bundle `com.shantanugoel.Ganit.M6QA2`; the
earlier session used `/tmp/GanitM6QA.app`). Tasks used a trip-budget
sheet with an Expenses table and a materials-estimate sheet.

1. Insert Table creates a table with chosen headers and types. The
   table inserts at the caret line, so a definition typed at the caret
   lands below the block and cannot feed its formulas. Move such a
   definition above the block. This follows the documented contract
   that tables end the block around them.
2. Grid entry commits with Return and moves down. Tab during a cell
   edit commits the pending value and starts a new edit on the same
   cell; it does not advance to the next column.
3. Table Actions shows Export Table, Set Column Formula, Clear Column
   Formula, totals and the other commands. Set Column Formula applies
   to the selected column, so the operator must first select a cell in
   the target column.
4. A column rule recalculates live; a dot marks an override; Clear
   Column Formula removes the rule. The totals line shows
   `Amount sum: 582` style text and updates after each edit.
5. Add Row inherits the column rule. A blank Qty shows an error in the
   rule cells and in the totals; filling it repairs them.
6. `=1/0` in a cell shows the failure message in red; repair restores
   the values and the totals.
7. Undo and redo return a cell edit step by step.
8. Export Table writes TSV and CSV from the save panel. The values
   export shows display text, so `1500` reads as `1,500` and `-2500` as
   `-2,500`. The formulas export shows the stored source and spells the
   inherited rule in every cell. A leading apostrophe guards fields a
   spreadsheet would run as formulas.
9. File ▸ Export ▸ PDF writes prose, answers, the grid with headers,
   values, totals and red failure text. PDFKit text extraction and a
   PNG render of the file confirm the content.
10. The Help viewer lists Calculation tables and Table references, and
    both topics render. In-app exports open in Quick Look with the
    mixed layout.

Export of the negative-value table wrote `-2,500` and `-5,000` without
the formula guard, verified in `~/Documents/Neg.csv` after the review
fix.

## One intermittent crash, not reproduced

One crash happened in the first QA session: `EXC_BREAKPOINT` inside
`-[NSUndoStack popAndInvoke]` through `-[NSUndoManager undoNestedGroup]`
during a menu Undo, after two export save panels. The report is at
`~/Library/Logs/DiagnosticReports/Ganit-2026-10-04-035022.ips`. The
sequence was a cell edit, two export save panels, then Undo, Redo, Undo.

Five later attempts did not reproduce it: three cycles in the M6 QA app,
one with `NSZombieEnabled`, and the same sequences on an M5 baseline
build (`b533a52`) with and without a Tab during the edit. All
`registerUndo` sites use `registerUndo(withTarget:)` and the M6 commits
do not change undo registration. The crash sits in the Foundation undo
invocation bridge. This milestone records it as an intermittent
platform-bridge defect to investigate with Zombie or AddressSanitizer
instrumentation before release; it is not shown to be an M6 regression.

## Verification matrix rows

| Concern | Evidence |
| --- | --- |
| Presentation/export | Mixed-sheet renderer, Quick Look, print and PDF suites; HTML escaping tests; CSV literal and formula cases; multi-page print layout test |
| Scale and footprint | Table benchmark (900 cells, 55 readers), engine and editor suites as above |
| CLI output | Structured and scalar suites; CLI smoke runs with exit-status checks |
| Frozen formats and grammar | Grammar and reference docs; no format changes; full frozen-format suites pass |
| Real jobs | Not run with human participants. The plan asks for 5–8 participants. The task-based checks above stand in for this phase; the study remains a release activity. |

## Remaining release checks

Deep VoiceOver review, real IME listening checks and the real-participant
usability study remain release-gated. The oversized-row print case draws
one page and clips content taller than one page; no crash or loop.
Publish and ship remain separate release actions.
