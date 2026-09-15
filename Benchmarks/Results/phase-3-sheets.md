# Phase 3 incremental sheet baseline

- Date: 2026-09-15
- Base commit: `19da5aabf8fd192cb428fbab38193669de203b4a` plus the fixture and
  benchmark change that records this file
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64

Fixtures are checked in under `Benchmarks/Fixtures/`; each ends with a newline,
so `SheetSource` reports one extra empty final line.

| Fixture | File | Lines | FNV-1a 64 | Edited line (0-based) | Lines evaluated per edit |
|---|---|---:|---|---:|---:|
| `mixed-sheet` | `mixed-sheet-1k.txt` | 1,000 | `b778c1d5cf78e02c` | 510 (`Meals:`) | 8 |
| `independent-sheet` | `independent-sheet-10k.txt` | 10,000 | `e4b4191e2f85d1f9` | 5,000 | 1 |
| `chained-dependency-sheet` | `chained-sheet-10k.txt` | 10,000 | `e66c09ca9d004832` | 0 (chain root) | 10,000 |

The mixed sheet repeats a 25-line section with headings, comments, labels,
multi-word variables, unit conversions, compound units, percentages, `line N`,
`previous`, subtotals, and block aggregates; it evaluates without failures. The
chained sheet declares `v0` and then `vN = vN-1 + k`, and the benchmark edits
its root, the worst case for propagation.

Command, run ten times per fixture as independent processes:

```sh
swift run --configuration release GanitBenchmarks --sheet <fixture> 500
```

Each process warms up with a throwaway calculator, times one full first
evaluation of a fresh calculator, then times 500 alternating one-line edits.
Each edit sample covers `SheetSource.replace` and `SheetCalculator.evaluate`:
segmentation update, dependency checks for every line, and re-evaluation of
affected lines. Samples exclude fixture loading, process launch, context
construction, formatting, and UI. P50 and P95 are nearest-rank percentiles per
process; reported values are the lower medians (`sorted[4]`) across the ten
runs.

| Fixture | Full evaluation | Edit P50 | Edit P95 | Highest run P95 |
|---|---:|---:|---:|---:|
| `mixed-sheet` | 23.838 ms | 0.702 ms | 0.853 ms | 0.899 ms |
| `independent-sheet` | 182.274 ms | 2.950 ms | 3.754 ms | 3.879 ms |
| `chained-dependency-sheet` | 265.849 ms | 26.879 ms | 28.747 ms | 28.887 ms |

Per-run samples as full/P50/P95 milliseconds:

- `mixed-sheet`: 24.79/0.707/0.899, 23.167/0.713/0.853, 23.445/0.711/0.884,
  23.838/0.701/0.796, 23.774/0.699/0.859, 24.511/0.698/0.861,
  24.321/0.704/0.84, 23.302/0.701/0.801, 24.955/0.702/0.837,
  24.09/0.704/0.892
- `independent-sheet`: 184.254/3.025/3.853, 209.824/3.059/3.854,
  178.212/2.925/3.609, 182.274/2.913/3.696, 182.02/3.02/3.828,
  183.937/3.041/3.879, 184.855/2.949/3.51, 181.058/3.009/3.78,
  179.945/2.95/3.754, 184.007/2.946/3.689
- `chained-dependency-sheet`: 268.259/27.021/28.819, 266.383/27.027/28.725,
  277.98/26.892/28.755, 265.849/26.751/28.746, 255.873/26.959/28.747,
  263.327/26.879/28.701, 266.237/26.862/28.595, 254.616/26.972/28.887,
  272.596/26.833/28.764, 257.898/26.713/28.834

## Against Section 8

The keystroke-to-visible-answer gates are 16 ms for a 1,000-line ordinary sheet
and 50 ms for a 10,000-line dependency stress sheet. These numbers are only the
engine-side portion. On this Mac the ordinary-sheet edit uses about 5% of its
budget. The worst-case root edit of the 10,000-line chain re-evaluates every
line, without reparsing, in under 58% of its budget, leaving about 21 ms for
layout and drawing. The gates are not passed until the editor measures
end-to-end latency, including on the documented M1 MacBook Air, 8 GB baseline.
