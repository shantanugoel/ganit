# Answers compared with other calculators

Ganit's answers next to another calculator's on the same input, so that a
difference is a decision rather than a surprise.

## How this was run

The expressions are the `phase-11-compatibility` fixture in
`Tests/GanitEngineCorpusTests/Fixtures`, so Ganit's column is pinned by the
golden corpus and cannot drift unnoticed. `scripts/compare-calculators.sh`
reads the same fixture, answers every line with both calculators, and prints
the table below.

- **Numi** answers through `numi-cli` v0.18.0, Numi's own engine in a
  terminal, alongside Numi 3.34 for Mac. Its terminal build does not implement
  time-zone conversion, CSS units, variables, or extensions, so the comparison
  avoids those.
- **Soulver** has no scriptable engine and is not installed here, so its
  documented answers are quoted from [soulver.app](https://soulver.app/) and
  [documentation.soulver.app](https://documentation.soulver.app/) in the last
  section rather than run.
- **Apple Math Notes** is out of scope by owner decision; it has no scriptable
  interface.

Ganit ran in the corpus context: `en-US`, 15 significant digits, UTC. Numi ran
with its own defaults, which round displays to two decimal places, so a
narrower Numi answer is usually its display and not its arithmetic.

## The comparison

Ganit 5c787c4, numi-cli v0.18.0.

| Expression | Numi | Ganit |
| --- | --- | --- |
| `2 + 3 * 4` | 14 | 14 |
| `(1 + 2) * 3` | 9 | 9 |
| `10 / 3` | 3.33 | 3.33333333333333 |
| `2^10` | 1024 | 1,024 |
| `2^100` | error | 1,267,650,600,228,229,401,496,703,205,376 |
| `1/3 + 1/6` | 0.50 | 0.5 |
| `sqrt(16)` | 4.00 | 4 |
| `sin(pi / 2)` | 1 | ≈ 1 |
| `1 / 0` | — | Cannot divide by zero. |
| `0xff + 1` | 0x100 | 256 |
| `1e3 + 1` | 1.001e3 | 1,001 |
| `20% of 85` | 17.00 | 17 |
| `85 + 20%` | 102 | 102 |
| `20% off 85` | 68.00 | 68 |
| `10% of 50 kg` | 5.00 kg | 5 kg |
| `50 kg - 10%` | 45 kg | 45 kg |
| `50 is what % of 200` | error | 25% |
| `20 inches in cm` | 50.80 cm | 50.8 cm |
| `12 km in miles` | 7.46 mi. | 7.45645430684801 mi |
| `5 km + 300 m` | 5300 m | 5.3 km |
| `1 kg in lbs` | 1 kg | 2.20462262184878 lb |
| `150 lb in kg` | 68.04 kg | 68.0388555 kg |
| `1 gal in L` | 3.79 L | 3.785411784 L |
| `16 oz in lb` | 1.00 lb | 1 lb |
| `100 km / 4 hours` | 25 h | 25 km/h |
| `1 hour in minutes` | 60 min | 60 min |
| `1 MB in bits` | 8000000 b | 8,000,000 bit |
| `100 Mb/s` | 100 Mb | 100 Mbit/s |
| `60 mi/h in km/h` | 60 mi. | 96.56064 km/h |
| `20 °C in °F` | 68.00 °F | 68 °F |
| `10 USD + 5 USD` | $15 | $15.00 |
| `$20 + $5` | $25 | This symbol is used by several currencies. Write a code such as USD. |
| `2024-01-31 + 1 month` | 2024-08-28 | Feb 29, 2024 |
| `15 Jan 2024 + 10 days` | 25 day | Jan 25, 2024 |
| `1 day in hours` | 24 h | This operation cannot combine these value types. |
| `3 pm + 2 hours` | 5 h | These quantities have incompatible dimensions. |
| `100 km/h in mph` | 100 km | 62.1371192237334 mph |
| `2 GB / 5 min in Mbps` | 0.40 min | 53.3333333333333 Mbps |
| `100!` | 100 | This character is not valid in an expression. |
| `2 + 2 = 4` | 4 | This character is not valid in an expression. |
| `75 mph in km/h` | 75 km | 120.7008 km/h |
| `170 lb in kg` | 77.11 kg | 77.1107029 kg |
| `32 °C in °F` | 89.60 °F | 89.6 °F |
| `15% of 490` | 73.50 | 73.5 |
| `55 USD + 25%` | $68.75 | $68.75 |
| `percentage change from 50 to 90` | error | 80% |
| `50% + 0.5` | 50.5 % | This operation cannot combine these value types. |
| `1/3 to 2 dp` | 0.33 | This part of the expression is unexpected. |

## Where the two agree

Precedence, parentheses, percentage phrases, unit conversion factors,
temperature conversion, money in a single currency, and tips all agree to the
digits both show. Where Ganit prints more digits, as in `10 / 3` or
`12 km in miles`, the value is the same and the difference is that Numi's
display stops at two decimal places while Ganit rounds to the sheet's
precision and keeps the exact value for Copy Full Precision.

## What Ganit refuses on purpose

- `$20 + $5` asks for a currency code, because `$` belongs to several
  currencies and guessing one would silently change an amount of money.
- `1 day in hours` refuses because a calendar day is not always 24 hours;
  `24 h in min` and the other fixed-duration conversions work.
- `3 pm + 2 hours` reads `pm` as picometres after a bare number, as the
  [ambiguity registry](../grammar/ambiguity-registry.md) records; `3:00 pm`
  is the time.
- `100!` and `2 + 2 = 4` are not in the grammar. Numi answers `100` and `4`
  respectively, dropping the part it does not understand.
- `50% + 0.5` has no single meaning: Soulver documents `100%`, Numi answers
  `50.5 %`, and Ganit asks instead of picking one.
- No phrase rounds an answer, so `1/3 to 2 dp` does not parse. Numi answers
  `0.33`; Ganit's sheet precision applies to every line instead.

## Where the other calculator quietly answers something else

These are the cases that justify pinning the corpus.

- `2^100` is an error in Numi, and `1 kg in lbs`, `60 mi/h in km/h`,
  `100 km/h in mph`, and `75 mph in km/h` come back as the input with a
  truncated unit, so a conversion Numi does not know looks like an answer.
- `100 km / 4 hours` answers `25 h` in Numi, labelling a speed with a time
  unit. Ganit answers `25 km/h`.
- `100 Mb/s` answers `100 Mb`, dropping the per-second.
- `15 Jan 2024 + 10 days` answers `25 day`, and `2024-01-31 + 1 month`
  answers `2024-08-28`.

## What this comparison changed in Ganit

- Added pound, ounce, gallon, `mph`, and `bps` to the unit catalog, from NIST
  SP 811 and IEC 80000-13 factors, so `1 kg in lbs`, `1 gal in L`, and
  `2 GB / 5 min in Mbps` answer instead of failing.
- Percentages now scale a quantity and keep its unit, so `10% of 50 kg` is
  `5 kg` and `50 kg - 10%` is `45 kg`. Absolute quantities still refuse:
  a tenth of 20 °C is a point on no scale.

Two rough edges remain. `1 day in hours` explains itself as a type mismatch
rather than naming the calendar reason, and `60 mph * 2 hours` answers
`120 h·mph` because a named speed unit does not cancel, while
`60 mi/h * 2 hours` answers `120 mi`.

## Soulver, from its documentation

Soulver's own pages publish these answers. Ganit's column was run here.

| Expression | Soulver, documented | Ganit |
| --- | --- | --- |
| `75 mph in km/hour` | 120.7 km/hour | 120.7008 km/h |
| `170 lb in kg` | 77.11 kg | 77.1107029 kg |
| `32 C to F` | 89.6 °F | 89.6 °F |
| `15% of 490` | 73.5 | 73.5 |
| `$55 + 25% tip` | $68.75 | $68.75 |
| `50 to 90 as %` | 80% | 80% as `percentage change from 50 to 90` |
| `1/3 to 2 dp` | 0.33 | not in the grammar |
| `50% + 0.5` | 100% | refused |

Every Soulver answer Ganit's grammar covers matches to the digits Soulver
shows. The two differences are the rounding phrase and percentage-plus-number,
both listed above. Soulver's line references, totals, and natural-language
range are wider than this table; the comparison here is limited to answers its
documentation states.
