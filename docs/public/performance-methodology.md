# Performance methodology

Ganit treats speed and footprint as release gates, measured in release builds
and recorded with the commit, hardware, system, and toolchain.

## What is measured

| Measure | Tool | How |
| --- | --- | --- |
| Keystroke → visible answer | `GanitBenchmarks --editor <fixture> 200` | A real editor in an offscreen window; each edit is timed from scheduling evaluation to the answer overlay having drawn that generation |
| Incremental evaluation | `GanitBenchmarks --sheet <fixture> 500` | One-line edits to 1,000- and 10,000-line fixtures |
| Single expression | `GanitBenchmarks --engine 10000` | Parse and evaluate after initialization |
| Cold launch → Quick Ganit | `scripts/measure-quick.sh` | New process with `--quick-ganit`, polled until its panel is on screen |
| Cold launch → sheet | `scripts/measure-launch.sh` | New process until its sheet window is on screen |
| Idle memory | `scripts/measure-quick.sh` | Physical footprint after settling |

Fixtures are deterministic files checked into the repository. Each result
reports P50 and P95 over repeated independent runs, with the first launch
after a build excluded as a warm-up.

## Gates

The gates and their current results are in PLAN §8.1 and
[Benchmarks/Results](../../Benchmarks/Results). A change that breaks a hard
gate is fixed or the budget is revised through an ADR with evidence; it is
never silently removed. When a number moves, the earlier commit is measured
again on the same machine the same day to separate code from machine state,
and a regression is bisected with the benchmark that shows it.

## Not yet done

All results so far come from one development Mac. Clean baseline hardware (an
M1 MacBook Air with 8 GB) and competitor comparisons are still to be run.
