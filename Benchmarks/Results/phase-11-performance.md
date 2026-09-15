# Phase 11 performance suite

- Date: 2026-09-15
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB — the
  development Mac, not a clean baseline machine
- System: macOS 26.6 (25G72)
- Configuration: release, arm64

This run is not the planned clean-machine comparison: no baseline M1 MacBook
Air was measured, and the only competitor measured is Numi's engine through
its terminal build, below. It checks every PLAN §8.1 gate that the benchmark
tools cover on the development Mac.

| Metric | Result (P95) | Gate |
| --- | ---: | ---: |
| Keystroke → visible answer, `mixed-sheet` (1,000 lines) | 6.8 ms | 16 ms |
| Keystroke → visible answer, `independent-sheet` (10,000 lines) | 14.4 ms | — |
| Keystroke → visible answer, `chained-dependency-sheet` (10,000 lines) | 47.3–48.0 ms | 50 ms |
| Simple single-expression evaluation (`--engine 10000`) | 0.016 ms | 1 ms |
| Cold launch → Quick Ganit | 380–414 ms | 450 ms |
| Cold launch → Workspace sheet | 378 ms | 700 ms |
| Quick Ganit idle footprint | 36–39 MB | 70 MB |
| Installed app size | 6.2 MB | 50 MB |

Commands: `GanitBenchmarks --editor <fixture> 200`, `GanitBenchmarks --engine
10000`, `scripts/measure-quick.sh 10`, `scripts/measure-launch.sh 10`.

## Regression found and fixed

The chained-dependency edit measured 72 ms P95, over its 50 ms hard gate. On
the same machine, the commit that recorded the Phase 4 result still measured
42 ms, so the regression was in code. Bisecting with that benchmark found
`bd5b753` (temporal values, 42 → 57 ms), with later value cases adding more.
Samples showed time in generic multi-payload enum copies of `EngineValue`,
a 171-byte enum copied at every evaluation step. Making the quantity, rate,
instant, and money cases `indirect` brought it to 48 ms. A plain-number fast
path in binary arithmetic was tried and made no difference, so it was not
kept.

The margin to the 50 ms gate is 2 ms. The remaining cost is spread across
variable lookups, hashing, and result copies.

## Numi, from the command line

Numi's terminal build, `numi-cli` v0.18.0, is the only competitor engine with
a scriptable interface, so it is the one comparison that can run here. Both
commands answer the same eight expressions from a cold process, 30 runs each,
on the same machine and in release configuration. `scripts/measure-cli.sh`
reproduces the table.

| Command | Median | P95 | Minimum |
| --- | ---: | ---: | ---: |
| `ganit EXPRESSION` | 10.6 ms | 20.2 ms | 8.7 ms |
| `numi-cli EXPRESSION` | 24.3 ms | 32.7 ms | 20.2 ms |
| `ganit < mixed-sheet-1k.txt` (1,000 lines) | 39.8 ms | 48.8 ms | 38.0 ms |

Nearly all of the first two rows is process start, not arithmetic: the engine
itself answers a single expression in 0.016 ms. The comparison that matters
for a sheet is the third row, because `numi-cli` answers one expression per
run, so a 1,000-line sheet costs it about 1,000 launches, roughly 24 seconds,
against 40 ms in one Ganit process.

This measures the two engines from a terminal, not the two apps. Comparing
launch, typing latency, or memory between the Mac apps needs a person driving
both interfaces on clean hardware.
