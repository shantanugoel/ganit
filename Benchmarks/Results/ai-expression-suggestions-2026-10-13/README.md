# Expression suggestion performance check

Date: 2026-10-13.

Baseline: `8ef58df`. Candidate: `de8b049`.

Both builds used Xcode 27.0 on the same MacBookPro18,2 with an Apple M1 Max
and 32 GiB of memory. The system was macOS 27.0, build 26A428. The Xcode
build was 27A266a. The baseline came from a separate source archive.

The release editor benchmark used offscreen windows and deterministic
fixtures. It did not load provider settings or send an AI request.
Suggestions were disabled. Each fixture had one excluded 20-edit warm-up
for each build. Three measured runs used 200 edits each. Build order
alternated between the baseline and candidate. Fixture bytes matched.
The JSON file records their SHA-256 digests and each run summary.

| Fixture | Existing P95 gate | Baseline P95 range | Candidate P95 range | Gate result |
| --- | --- | --- | --- | --- |
| 1,000-line mixed sheet | 16 ms | 28.815–28.832 ms | 28.550–28.554 ms | Both fail |
| 10,000-line dependency sheet | 50 ms | 130.688–131.283 ms | 130.677–131.267 ms | Both fail |

The observed candidate results are close to the baseline results. They do
not establish a passing release gate. No gate or budget was changed.
The earlier release results must not replace this failed check. The cause
of the baseline failure is not established by these measurements.

Active-job performance, a clean 8 GB baseline Mac, launch, idle memory,
and the remaining release measurements still need work. These results do
not complete a phase exit gate.

Run each measured fixture with:

```sh
swift run --skip-build --configuration release GanitBenchmarks --editor mixed-sheet 200
swift run --skip-build --configuration release GanitBenchmarks --editor chained-dependency-sheet 200
```

See [the run summaries](results.json), the adjacent raw output files,
[the methodology](../../../docs/public/performance-methodology.md), and
[the implementation plan](../../../docs/plans/ai-expression-suggestions.md).
