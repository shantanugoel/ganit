# ADR 0010: Parse English grammar with an explicit sheet locale

- Status: Accepted
- Date: 2026-09-14

## Context

Locale affects decimal and grouping separators, digit shapes, currency symbols, dates, calendars, and display, while source text must remain deterministic after it is saved. Reading `Locale.current` inside the engine would make the same sheet change meaning when opened on another Mac. Accepting multiple separators at once would turn inputs such as `1,234` into silent guesses.

## Decision

### P0 language and locales

- Natural-language keywords and function names are English only.
- P0 parsing fixtures cover `en-US`, `en-GB`, `en-IN`, `de-DE`, `fr-FR`, and `ar-EG`.
- The engine receives a BCP 47 locale identifier and explicit separator/grouping syntax in immutable `EvaluationContext`; it never reads a global current locale.
- New sheets capture the user's selected locale. Sheet metadata and `.ganit` manifests persist that identifier. Plain-text import requires an explicit import locale, defaulted visibly from the current app preference.

### Numbers

- The locale's declared decimal and grouping separators are the only accepted separators. There is no cross-locale fallback.
- Grouping is optional. When present, every group must match the locale's primary and secondary grouping sizes.
- Function arguments use a semicolon in comma-decimal locales; a comma followed by whitespace remains accepted when it cannot be a decimal separator.
- Unicode decimal digits are converted by numeric value, but one literal may not mix digit scripts.
- Accept ASCII hyphen-minus and Unicode minus as signs. Scientific exponents use `e` or `E`.
- Preserve source text exactly. Parsed finite decimals store coefficient and scale; canonical diagnostic and interchange values use ASCII digits, `-`, and `.` with no grouping.

Thus `1,234` is one thousand two hundred thirty-four in `en-US` and the exact decimal 1.234 in `de-DE`. The persisted locale makes that distinction deterministic.

### Dates, money, and display

- ISO 8601 dates are always accepted when Phase 7 lands. Materially ambiguous numeric date order requires a visible choice rather than locale guessing.
- Ambiguous currency symbols use an explicit sheet currency preference or produce an ambiguity; locale is evidence, not permission to guess.
- Formatting receives the same locale explicitly and never reparses source.
- Changing a sheet locale is an explicit document operation that reevaluates the sheet and surfaces changed or newly ambiguous lines. It never rewrites source.

Unsupported locale syntax produces a ranged diagnostic. Locale expansion adds fixtures and a reviewed grammar/data change; it does not add hidden compatibility aliases.

## Consequences

- A sheet has stable meaning across machines and user preference changes.
- Phase 1 lexer ranges and decimal tokens have concrete separator and digit rules.
- Phase 7 date parsing and Phase 8 currency symbols inherit conservative ambiguity behavior.
- Additional parser languages remain separate grammar modules rather than translated keyword lists.

## References

- [Unicode Locale Data Markup Language: Numbers](https://unicode.org/reports/tr35/tr35-numbers.html)
- [Unicode Locale Data Markup Language: Dates](https://unicode.org/reports/tr35/tr35-dates.html)
- [Foundation Locale](https://developer.apple.com/documentation/foundation/locale)
