# Phase 6 Quick Ganit invocation baseline

- Date: 2026-09-15
- Base commit: `8d05eea16a2b7837ef9f332472da2c3c4e38d38d` plus the measurement
  change that records this file
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64, ad-hoc signed App Sandbox and Hardened Runtime

## Cold launch to Quick Ganit

```sh
./scripts/build-app.sh release
./scripts/measure-quick.sh 20
```

For each sample, the launch probe starts a new Ganit process with
`--quick-ganit` and polls Core Graphics until that process shows a window at the
floating level used by the Quick Ganit panel. The panel is ordered front and its
text made first responder in the same run-loop turn. Measurements exclude the
probe's compilation and the app build, and the first launch after building (a
cold file cache) was excluded by running a warm-up launch before these samples.

- P50: 219.546 ms
- P95: 242.747 ms
- Samples in run order (ms): 246.954, 213.594, 233.207, 227.746, 211.159,
  228.915, 212.985, 235.914, 225.416, 214.818, 212.519, 214.239, 209.487,
  240.764, 234.749, 219.546, 218.508, 242.747, 233.248, 210.778

## Resident invocation

```sh
swift run --configuration release GanitBenchmarks --quick 200
```

The benchmark creates one panel, shows and hides it once, and then times 200
calls to `show()` followed by drawing the panel, verifying each time that it is
visible with its text focused. This is the work done when the global shortcut
fires in a running Ganit; hot key event delivery is excluded. Five processes:

| Run | Panel creation | Show P50 | Show P95 |
|---:|---:|---:|---:|
| 1 | 78.594 ms | 8.085 ms | 15.804 ms |
| 2 | 70.644 ms | 7.771 ms | 15.218 ms |
| 3 | 75.113 ms | 7.903 ms | 15.730 ms |
| 4 | 67.344 ms | 6.937 ms | 14.484 ms |
| 5 | 64.953 ms | 7.905 ms | 14.767 ms |

The panel is created on first use, so the first invocation after launch adds
about 70 ms of creation to the show time.

## Idle memory

`measure-quick.sh` then launches Ganit with only Quick Ganit open, waits five
seconds, and records:

- `phys_footprint` from `footprint`: 25 MB
- RSS from `ps`: 91,760 KiB, which includes shared system mappings

## Against Section 8

| Gate | Target | Measured here |
|---|---:|---:|
| Global-hotkey panel, resident process → focused | P95 ≤ 100 ms | 15.8 ms highest run P95; about 86 ms for the first invocation, which creates the panel |
| Cold launch → focused editable quick panel | P95 ≤ 450 ms | 242.7 ms |
| Quick panel idle resident memory | ≤ 55 MB target, ≤ 70 MB hard gate | 25 MB physical footprint |

All three are within budget on this Mac. The gates remain unproven until they
are measured on the documented M1 MacBook Air, 8 GB baseline and minimum macOS.
