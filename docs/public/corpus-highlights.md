# Correctness corpus highlights

Ganit's answers are pinned by a versioned golden corpus that runs on every
change: 207 expressions with their exact displayed answer, full-precision
answer, or diagnostic code, message, and source range. It is run again under
Address Sanitizer, alongside property tests and parser fuzzing.

| Fixture | Cases | What it pins |
| --- | ---: | --- |
| `phase-1-golden` | 11 | Exact integers, fractions, decimals, approximation marks, errors |
| `phase-2-percentages` | 8 | Percentage phrases and precedence |
| `phase-2-conversions` | 11 | Unit conversions and compound units |
| `phase-2-ambiguities` | 55 | The five registry rules one expression can show; the two about how a line's name is read are pinned by unit tests |
| `phase-7-dates` | 50 | Leap years, month ends, daylight saving, zone history, relative dates |
| `phase-10-finance` | 10 | Future value, present value, and loan payments |
| `phase-10-statistics` | 14 | Sum, average, median, and count over a listed set of values |
| `phase-11-compatibility` | 48 | Answers other calculators also publish or compute |

Some examples:

| Input | Answer |
| --- | --- |
| `2024-01-31 + 1 month` | Feb 29, 2024 |
| `2024-03-10T02:30 America/New_York` | This time is skipped when clocks move forward in this time zone. |
| `2011-12-30T12:00 Pacific/Apia` | This time is skipped when clocks move forward in this time zone. |
| `fv(10000 USD, 5%, 10)` | ≈ $16,288.95 |
| `$5` | This symbol is used by several currencies. Write a code such as USD. |
| `3 pm` | 3 pm (picometres) |

Beyond the corpus, property tests check arithmetic identities and unit round
trips with fixed seeds, and a nightly workflow fuzzes 50,000 fresh inputs.
Answers are also compared with Numi's engine and with Soulver's documented
answers, and every difference is a recorded decision; see the
[answer comparison](../quality/compatibility.md) and
[known limitations](../reference/known-limitations.md).
