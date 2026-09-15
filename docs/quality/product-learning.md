# Product learning

Ganit learns what to improve without watching anyone calculate.

## Never

- No automatic analytics, telemetry, crash upload, or expression logging. Tests
  enforce it: app modules may not log (`appModulesDoNotLog`) and only the
  exchange-rate downloader and the assistant may use the network
  (`onlyTheRateDownloaderUsesTheNetwork`). The assistant is off until someone
  sets it up, and then carries one line at a time and nothing else.
- No collection hidden behind a default or a first-launch prompt.

## Voluntary feedback

**Help ▸ Report a Problem…** saves a [problem report](problem-reports.md) that
the user reads and sends. Sheet text is included only when they tick the box.

## Support themes

Each release candidate reviews the reports and messages received since the last
one and records recurring themes — a confusing answer, a missing unit, a
workflow that took too long — with a count and one anonymized example, never a
person's sheet. Themes feed `PLAN.md` priorities, the
[ambiguity registry](../grammar/ambiguity-registry.md), and
[known limitations](../reference/known-limitations.md).

## Opt-in studies

Task-based usability sessions (PLAN §15.2) recruit participants who agree to
take part, use sample sheets rather than their own data, and record completion,
time, corrections, and confidence. Results are kept as aggregate notes without
names. None have been run yet.
