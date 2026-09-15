# Phase 4 edit-to-answer baseline

- Date: 2026-09-15
- Base commit: `2acd47f8904b1f96a4980a05d52355ebbb6fedf3` plus the
  instrumentation change that records this file
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64

Command, run five times per fixture as independent processes:

```sh
swift run --configuration release GanitBenchmarks --editor <fixture> 200
```

The benchmark opens a real `SheetEditorViewController` in an offscreen
900 × 700 pt window with the [Phase 3 sheet fixtures](phase-3-sheets.md). For
each of 200 alternating edits it scrolls the benchmark line into view, replaces
the line through `NSTextView.insertText(_:replacementRange:)`, and pumps the
main run loop, forcing window display, until the editor reports
edit-to-answer latency. That interval starts when the edit schedules a
generation and ends after the answer overlay has drawn that generation: text
storage mirroring, incremental evaluation on the worker actor, commit,
selective decoration, answer layout, formatting of visible answers, and drawing.
It excludes input-event dispatch and window-server compositing. Samples are
nearest-rank percentiles per process; reported values are lower medians
(`sorted[2]`) across the five runs.

| Fixture | Edited line | P50 | P95 | Highest run P95 | Gate |
|---|---|---:|---:|---:|---:|
| `mixed-sheet` (1,000 lines) | `Meals:` | 6.380 ms | 6.821 ms | 7.679 ms | 16 ms |
| `independent-sheet` (10,000 lines) | line 5,001 | 15.987 ms | 17.358 ms | 17.991 ms | — |
| `chained-dependency-sheet` (10,000 lines) | chain root | 41.389 ms | 43.498 ms | 51.363 ms | 50 ms |

Per-run P50/P95 samples in milliseconds:

- `mixed-sheet`: 6.459/7.679, 6.382/6.891, 6.35/6.745, 6.369/6.821, 6.38/6.706
- `independent-sheet`: 16.061/17.782, 16.324/17.991, 15.912/17.357,
  15.987/17.358, 15.796/17.205
- `chained-dependency-sheet`: 41.389/42.968, 41.488/43.498, 41.079/43.496,
  41.462/43.692, 41.262/51.363

## Against Section 8

On this Mac the 1,000-line ordinary sheet meets its 16 ms gate with room for
event dispatch and compositing. The worst-case 10,000-line dependency edit, which
re-evaluates all 10,000 lines, has a median P95 under 50 ms but one run's P95
exceeded it, and about two thirds of that time is engine evaluation. It is at
risk on the documented M1 MacBook Air, 8 GB baseline, where the gate must be
measured before release.

Before this instrumentation, committing a generation rebuilt and formatted an
answer cell for every line and redecorated every line; the same benchmark
measured P95 values of 14 ms, 87 ms, and 1,100 ms. Answers are now formatted only
for drawn lines and cached by value, and only lines whose text, role, or failure
state changed are redecorated.

Signposts `EditToAnswer`, `Evaluation`, and `AnswerLayout` appear under Points
of Interest in Instruments for the same intervals in the app.
