# Ambiguity registry

**Registry version:** 1

This registry records how the English grammar resolves inputs that could
reasonably mean more than one thing. Every entry is pinned by named cases in
`Tests/GanitEngineCorpusTests/Fixtures/phase-2-ambiguities.json`; case names
start with the entry ID. Changing a policy is a language change: bump the
registry version, update the corpus, and add release notes.

The general rule is conservative: when the grammar cannot pick one meaning
deterministically, it reports a ranged diagnostic instead of guessing.

## `%` — percent versus modulo

- `%` is only the percentage marker, with or without a space: `20 %` is `20%`.
- `%` never means modulo. `10 % 3` and `5%3` fail at the operand after `%`.
- A percentage cannot be marked twice: `50%%` fails at the second `%`.
- `mod` is not an operator yet; `10 mod 3` fails at `mod` rather than being
  ignored.

## `in` — conversion versus inch alias versus prose

- After a numeric literal, prefixed number, or parenthesized number, `in` is
  the inch alias: `12 in`, `12in`, `-5 in`, `12 in^2`.
- After a quantity, `in` is a conversion keyword when a unit follows:
  `12 km in miles`, `12 in in cm`, `1 ft in in`.
- After any quantity-valued expression, including groups and computed
  quantities, a trailing `in` is an incomplete conversion, never an inch
  suffix: `(1 m + 2 m) in`, `(1 m * 2) in`.
- An inch alias followed by a bare unit is not reinterpreted as a conversion:
  `1 m + 2 in cm` fails at `cm`. Write `1 m + 2 in in cm`.
- A bare number cannot be converted, so `5 in miles` fails at `miles`.
- Exponents are dimensionless, so `in` after an exponent is never inches:
  `(3 m)^2 in cm^2` converts, and `2^3 in` fails at `in`.
- Prose is never skipped: `price in dollars` fails at `in`.

`to`, `as`, and `into` are conversion keywords with the same rules and have no
unit meaning.

## `symbols` — unit symbols, constants, and currency signs

- Unit aliases and prefixes are case-sensitive and never case-corrected:
  `m` is metre, `M` alone is not a unit, `Mm` is megametre, `mm` is millimetre,
  `KM` fails.
- `b` is bit and `B` is byte, so `Mb` is megabit and `MB` is megabyte.
- An exact catalog alias wins over a prefix split: `min` is minute, `h` is
  hour, and `mi` is mile. Remaining aliases split into a permitted prefix and
  unit: `ms` is millisecond.
- An identifier followed by `(` is a function call: `min(1, 2)`.
- Constants are not units: `2pi` is implicit multiplication and `2 e` fails.
- Currency signs are not accepted until currency support defines their
  locale resolution: `$5` and `¥5` fail as unexpected characters.

## `implicit multiplication` — products versus adjacent quantities

- Implicit multiplication requires no whitespace, a number/group/call on the
  left, and a group, identifier, or (for non-literals) number on the right:
  `2(3 m)` is `6 m` and `(2 m)(3 m)` is `6 m^2`.
- Whitespace never multiplies: `2 3` fails.
- Adjacent quantities are neither summed nor multiplied: `5 ft 3 in` fails at
  `3`. Write `5 ft + 3 in`.
- Unit products must be explicit: `2 kg m` fails; write `2 kg·m`.
- A quantity does not implicitly multiply what follows: `2 m(3)` and `3 m 2`
  fail.
- Units attach only to numbers and grouped numbers, not computed constants:
  `2π m` fails; write `(2π) m`.
- Identifiers are not split into digits and units: `5ft3in` is the number `5`
  times the unknown identifier `ft3in`.

## `identifiers` — variable names versus prose and typos

- Unknown identifiers are errors, never ignored prose: `tax + 1` fails with
  `evaluation.unknownIdentifier` until `tax` is declared above it.
- A multi-word name matches the longest declared name across adjacent words:
  with `rent` and `rent total` declared, `rent total` is the second variable.
- Names cannot use keywords, constants, function names, or unit aliases, so
  `in = 1`, `pi = 3`, `min = 1`, `km = 5`, and `total km = 3` fail with
  `syntax.invalidVariableName`. Declaration rejects the collision instead of
  letting a variable shadow built-in meaning.
- Reference keywords (`line`, `previous`, `prev`, `sum`, `total`, `subtotal`,
  `average`, `avg`, `median`, `count`) cannot be a whole variable name, but a
  declared longer name wins: with `total rent` declared, `total rent` is the
  variable and `total` alone is the aggregate.

