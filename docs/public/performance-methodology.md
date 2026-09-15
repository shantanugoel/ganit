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
| Quick panel idle memory | `scripts/measure-quick.sh` | Physical footprint after settling |
| Workspace idle memory | `scripts/measure-launch.sh` | Physical footprint after settling with a 1,000-line sheet restored |

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
M1 MacBook Air with 8 GB) is still to be measured.

Numi is the one competitor measured. Its engine from the command line answers
one expression in 24.3 ms against `ganit`'s 10.6 ms, both mostly process
start. App to app, Ganit idles at 34 MB with a 1,000-line sheet open against
Numi's 54 MB with no window open, in a 6.2 MB bundle against 44.8 MB.
Comparing launch and typing latency needs a person, because Numi puts no
window on screen until someone clicks its menu bar item, so there is nothing a
script can wait for.

The memory budgets are read as physical footprint, the memory the app itself
costs, not resident set size, which counts shared system framework pages that
every AppKit process maps.
