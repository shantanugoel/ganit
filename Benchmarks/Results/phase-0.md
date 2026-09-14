# Phase 0 release baseline

- Date: 2026-09-14
- Commit under test: `4a4201ebff2829ccbd0b240d37cad156ba1b2a9a`
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64, ad-hoc signed App Sandbox and Hardened Runtime

## Launch-to-visible-window

Command:

```sh
./scripts/build-app.sh release
./scripts/measure-launch.sh 20
```

The harness starts a fresh Ganit process for each sample and polls Core Graphics until that process owns an on-screen layer-zero window. It excludes harness compilation and app build time.

- P50: 182.780 ms
- P95: 195.098 ms
- Samples in run order (ms): 208.816, 182.780, 178.034, 170.725, 195.098, 184.034, 183.223, 174.637, 176.602, 182.117, 186.108, 181.563, 183.199, 193.792, 185.716, 174.593, 180.443, 183.283, 180.757, 184.348

This is a warm-filesystem, process-cold development baseline on a faster machine than the planned M1 MacBook Air baseline. It does not prove the cold-launch release gate.

## Footprint

Measured after building the same release bundle:

- App bundle disk allocation: 100 KiB
- Main executable: 82,912 bytes
- `ditto` ZIP including the app: 18,076 bytes
- Settled process RSS from `ps`: 78,176 KiB
- Settled memory shown by the second `top` sample: approximately 16 MiB
- Settled CPU and `top` power score over a one-second sample: 0.0% and 0.0

The app was left idle for more than 20 seconds before process measurements. RSS includes shared mappings and is recorded alongside `top` because the tools account for memory differently.

Per-process package-idle wakeups were not captured: `powermetrics` requires administrator authorization on this machine. A zero `top` power score is not proof of zero wakeups. The release idle-energy gate remains unverified until the Phase 4 diagnostics/instrumentation work runs Instruments or an authorized `powermetrics` procedure on the documented baseline hardware and minimum macOS.

## Interpretation

These values establish a reproducible Phase 0 regression baseline and prove that the launch path reaches a visible standard window. They are not a claim that the Section 8 launch, memory, energy, or size release gates pass on required hardware.
