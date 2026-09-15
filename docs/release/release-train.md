# Release train

Releases leave on a schedule, not when a feature feels finished: a release
candidate is cut every four weeks from `main`, and anything not ready waits
for the next train. A data-loss, crash, silent-wrong-answer, or security fix
may ship between trains.

## Every change

- CI is green: formatting, all package tests, the command-line and harness
  checks, the corpus under Address Sanitizer, the pseudolocalized layout, and
  app bundle verification.
- A fixed parser or evaluator bug lands with its regression test: a golden
  corpus case for a wrong answer or diagnostic, or a `parser-fuzz-seeds.json`
  entry for a crash or hang, added before or with the fix.
- A change to an existing answer bumps the ambiguity registry, updates the
  corpus, and adds a line to [`CHANGELOG.md`](../../CHANGELOG.md).
- A change to a frozen format follows [schema freeze](../reference/schema-freeze.md).

## Cutting a release candidate

1. Confirm the last four nightly fuzz runs passed, and triage any that did not.
2. Run the performance suite ([methodology](../public/performance-methodology.md))
   and record it in `Benchmarks/Results`; a hard gate that fails blocks the
   train.
3. Walk the "Needs a person" rows of the [section 9 matrix](../quality/section-9-matrix.md).
4. Rehearse the [recovery guide](../storage/recovery-guide.md) on the
   candidate.
5. Move the `CHANGELOG.md` Unreleased entries under the new version, and bump
   `CFBundleShortVersionString` and `CFBundleVersion` in `App/Info.plist`.
6. Build with `scripts/release.sh` ([distribution](distribution.md)) and
   publish the disk image as a GitHub release.
