# Unit and conversion syntax

Phase 2.5 adds catalog-aware quantity literals and explicit result-unit selection.
The unit catalog is the authority for accepted unit names, aliases, and prefixes.

## Grammar

```text
quantity       := number unit-expression | unit-expression number
conversion     := expression ("in" | "to" | "as" | "into") unit-expression
unit-expression := unit-factor (("*" | "×" | "·" | "/") unit-factor)*
unit-factor    := unit-name unit-power?
                | "(" unit-expression ")" unit-power?
unit-power     := "^" ("+" | "-")? integer | "²" | "³"
unit-factor    := ("sq" | "square" | "cu" | "cubic") unit-name
```

Whitespace between a number and its unit is optional: `12 km` and `12km` are
equivalent. The unit may also come first: `km 12` and `km/h 60`. Products must
be explicit inside units. Examples include `75 MB/s`,
`9.81 m/s^2`, `1 kg·m/s²`, and `1 m/(s^2)`. Mixed units add: `5 ft 10 in` is `5.83333333333333 ft`. A power may be a word before its
unit: `1200 sq ft`, `2 cubic m`; a declared variable with that name is still
the variable.

Unit exponents, nesting, token counts, factor counts, and dimension exponents
are subject to the engine's existing syntax and evaluation limits.

## Catalog resolution and case

Aliases and prefixes are case-sensitive. `m`, `M`, `B`, and `b` can therefore
have different meanings. The parser first checks an entire alias, then tries to
split an attached prefix from a unit alias. A split is accepted only when that
unit permits the prefix family. For example, `km`, `MB`, and `KiB` are valid;
unsupported casing such as `KM` and `KB` is not silently corrected.

Catalog lookup is deliberately conservative. Arbitrary identifiers are not
treated as units, so arithmetic such as `2pi` retains its implicit
multiplication meaning. A [custom unit](definitions.md) joins the catalog under
its own name and English plural, takes no prefix, and resolves exactly as a
built-in unit does. A terminal `in` following a number is the inch alias
(`12 in`); after an established quantity it is a conversion keyword
(`12 km in miles`).
The [ambiguity registry](ambiguity-registry.md) records the complete `in`,
unit-symbol, and implicit-multiplication policies.

## Precedence and result-unit selection

Conversion keywords have lower precedence than arithmetic and percentage
phrases. The target applies to the complete expression on its left:

```text
1 m + 1 ft in cm
```

is interpreted as `(1 m + 1 ft) in cm`. The converted `QuantityValue` stores the
explicit target unit, and formatting uses that unit instead of selecting a
prettified alternative. All four keywords have identical semantics.

Percentage change keeps its phrase grammar: `percentage change from 80 to 100`
does not interpret `to` as conversion because the following token is not a
catalog unit.

## Dimensional and affine rules

Addition and subtraction require compatible dimensions and retain the left
operand's unit until an explicit conversion changes it. Relative quantities
support scalar multiplication/division, quantity multiplication/division, and
bounded integer powers. Incompatible conversions produce a ranged
`evaluation.incompatibleDimensions` diagnostic. When multiplication, division, or a power cancels every dimension, the result
is a plain number in canonical scale: `1 km / (1 m)` is `1,000`.

Affine temperature units are valid only as standalone absolute quantities,
such as `0 °C`, and can be explicitly converted (`0 °C as °F`). They cannot
participate in compound unit algebra, scalar scaling, powers, or ordinary
addition/subtraction. Temperature differences are not yet separate syntax, so
relative temperature arithmetic remains unavailable.

## Current limitations

- Quantity suffixes attach to numeric literals and explicitly grouped numeric
  expressions, not arbitrary prose or unresolved identifiers.
- Superscript shorthand currently recognizes `²` and `³`; other powers use
  `^` followed by a signed decimal integer.
- Calendar periods and currencies are outside Phase 2.5; user-defined units
  arrive with [definitions](definitions.md).
