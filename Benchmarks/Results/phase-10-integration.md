# Phase 10 integration gates

- Date: 2026-09-15
- Base commit: `a56fe2b`
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Configuration: release, arm64, ad-hoc signed App Sandbox and Hardened Runtime

Phase 10 must not regress the launch, idle, and bundle hard gates (PLAN §8.1).

| Metric | Result | Hard gate |
| --- | ---: | ---: |
| Cold launch → focused Quick Ganit, P95 (`measure-quick.sh 10`) | 380–414 ms | 450 ms |
| Cold launch → focused Workspace sheet, P95 (`measure-launch.sh 10`) | 378 ms | 700 ms |
| Quick Ganit idle physical footprint | 36–39 MB | 70 MB |
| Installed app size | 6.2 MB | 50 MB |

## Same-day baseline

Quick Ganit cold launch measured 243 ms P95 in the Phase 6 results. To check
whether Phase 10 caused the difference, the Phase 6 commit (`739282c`) and the
last commit before Phase 10 (`71616d3`) were built and measured on the same
machine minutes later:

| Commit | P50 |
| --- | ---: |
| `739282c` (Phase 6) | 358 ms |
| `71616d3` (before Phase 10) | 361 ms |
| `a56fe2b` (Phase 10 complete) | 365 ms |

All three agree, so the change since Phase 6 comes from the machine's state
on the day rather than from code. Timing inside the app showed about 200 ms
spent in AppKit between `applicationWillFinishLaunching` and
`applicationDidFinishLaunching`, with Ganit's own setup under 10 ms. The launch
path adds no network request: the exchange-rate refresher starts one only when
a refresh is due, and the Spotlight index does nothing unless enabled.
