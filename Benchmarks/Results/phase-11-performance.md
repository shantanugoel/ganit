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

## Re-measured after the answer-comparison changes

The unit catalog and percentage-on-quantity changes touch the evaluation path,
so the suite ran again on the same machine and day, from a fresh release build
of the bundle.

| Metric | Result (P95) | Gate |
| --- | ---: | ---: |
| Keystroke → visible answer, `mixed-sheet` (1,000 lines) | 8.6 ms | 16 ms |
| Keystroke → visible answer, `independent-sheet` (10,000 lines) | 16.0 ms | — |
| Keystroke → visible answer, `chained-dependency-sheet` (10,000 lines) | 49.4–49.9 ms | 50 ms |
| Simple single-expression evaluation (`--engine 10000`) | 0.016 ms | 1 ms |
| Cold launch → Quick Ganit | 383 ms | 450 ms |
| Cold launch → Workspace sheet | 461 ms | 700 ms |
| Quick Ganit idle footprint | 32 MB | 70 MB |
| Installed app size | 6.2 MB | 50 MB |

Every gate still passes, but the chained-dependency edit now passes by about
half a millisecond rather than the 2 ms measured earlier the same day, so it
is worth being precise about why.

That difference is machine state, not these changes. Following the
methodology's rule, the commit before them, `5c787c4`, was built and measured
on this machine immediately afterwards: 50.0, 49.5, and 49.8 ms P95 against
49.7, 49.4, and 49.9 ms at `a6666b8`. The two are indistinguishable, and the
chained fixture contains only variable chains, no units and no percentages, so
neither change is in its path. The first run of the session measured 52.3 ms
and the next three did not, so a run immediately after building and launching
the app is warm-up and is discarded.

The launch and footprint figures come from five samples each rather than ten,
which is why the sheet launch P95 of 461 ms sits above the 378 ms recorded
above while its P50, 336 ms, does not; one slow sample moves a five-sample
P95.

A profile of the chained edit shows the remaining time is the evaluation
itself, spread across 10,000 dependent lines at roughly 5 µs each, with answer
text measurement during drawing next. No cheap win was visible, and the
budget still passes, so nothing was changed for it. The honest summary is that
this gate has under a millisecond of headroom on this machine and will need
either an optimization or an ADR revision the next time it moves.

## Workspace idle memory, measured for the first time

The quick panel's idle memory had a script and a recorded result; the
workspace row of PLAN §8.1 had neither. `scripts/measure-launch.sh` now
reports idle memory as well as launch, so both rows are measured the same way.

The sheet it restores is the 1,000-line `mixed-sheet` fixture, copied into the
app's container as its most recent sheet with a matching checksum so no
recovery path runs.

| Measure | Result | Target | Hard gate |
| --- | ---: | ---: | ---: |
| Cold launch → Workspace sheet, 1,000 lines | 354 ms P50, 401 ms P95 | — | 700 ms |
| Workspace idle physical footprint | 34 MB | 85 MB | 110 MB |
| Workspace idle resident set size | 101 MB | — | — |

The two memory budgets are read as physical footprint, which is what the app
costs; resident set size counts shared system framework pages that every
AppKit process maps and that no application choice changes. Both are reported
here so the distinction is explicit rather than assumed: the quick panel is
32 MB footprint and 97 MB RSS, so reading these budgets as RSS would fail a
gate that the app's own memory passes with room to spare.

## Numi, app to app

Numi 3.32.721, installed from its Homebrew cask, is the only competitor app
present here. Two of the three app-to-app comparisons the plan asks for can be
measured without a person, and one cannot.

| Measure | Ganit | Numi |
| --- | ---: | ---: |
| Idle physical footprint | 34 MB | 54 MB |
| Idle resident set size | 101 MB | 133 MB |
| Installed bundle | 6.2 MB | 44.8 MB |

Ganit's figures are the harder case: it is idling with a window open on a
1,000-line sheet, while Numi is idling with no window on screen at all.

Launch to a visible window could not be measured for Numi. Run either by its
executable or through `open`, it reaches its run loop and stays without
putting any window on screen, so the window probe that times Ganit finds
nothing to wait for; its calculator window appears when a person clicks its
menu bar item or presses its hotkey. Typing latency needs a person for the
same reason. Those two comparisons remain genuinely blocked on someone driving
both interfaces.

One observation from launching it: Numi's own log shows it fetching
`s1.numi.app/config` and `s.numi.app/rates` on every launch. Ganit answers
everything but currency without the network, and answers currency from the
snapshot already on disk.
