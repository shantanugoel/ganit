# Reviewed minimal unit catalog

`UnitCatalog.minimal()` contains the P0 units needed by the launch scenarios
and the named dimensions in the product plan. The initial set covers SI base
and derived units, liters, international inches/feet/miles, civil time units,
Celsius/Fahrenheit, angles, and decimal and binary data units.

Pounds, ounces, gallons, `mph`, and `bps` joined it after the
[answer comparison](../quality/compatibility.md) found that a US-customary
weight or volume, a speed in miles per hour, and a bandwidth in bits per
second had no answer at all. A named speed, data-rate, or energy unit carries
the compound dimension but not its factors, so `60 mph * 2 hours` answers
`120 h·mph` where `60 mi/h * 2 hours` answers `120 mi`.

The everyday units a person reaches for outside engineering followed: the
yard; the hectare and acre; the quart, pint, cup, fluid ounce, tablespoon, and
teaspoon; the tonne and stone; the bar, atmosphere, and `psi`; the
thermochemical calorie and the watt-hour. The liter also answers to `l`, so
`ml`, `cl`, and `dl` read as a decimal prefix on it, and `milliliters` reads as
the prefix's long name. Every one of them is an exact rational conversion.

Electronics followed: electric current joined the base dimensions, with the
ampere, volt, ohm (`Ω` or `ohm`), farad, henry, coulomb, ampere-hour, and hertz,
each taking decimal prefixes (`mA`, `kΩ`, `nF`, `mAh`, `MHz`). The mechanical
horsepower and the electronvolt (`keV`, `MeV`) are exact too. `A`, `V`, `C`,
`F`, and `H` are units now, so they cannot name a variable.

Each entry records:

- a stable Ganit-owned identifier and canonical symbol;
- conservative, case-sensitive English aliases;
- its dimension and ratio or affine transform;
- whether the transform is exact in Ganit's current numeric representation;
- a source identifier resolving to title, revision, URL, terms, and notice,
  which a [custom unit](../grammar/definitions.md) does not have, being a
  person's own data rather than a published definition, and so is absent from
  the attribution notice.

“Exact” describes the stored transform, not only the mathematical source
relation. The degree is therefore marked approximate: BIPM defines
`1° = π/180 rad` exactly, while the current numeric model has no symbolic π
ratio and explicitly stores a binary floating-point approximation.

All 24 SI prefixes from quetta through quecto and all ten IEC binary prefixes
from kibi through quebi are included with exact factors and case-sensitive
symbols. Unit definitions declare allowed prefix families. Decimal prefixes
apply to supported SI and data units; binary prefixes apply only to bit and
byte. This prevents constructions such as kibimeters.

The bare symbols `m` and `h` necessarily overlap across namespaces: meter and
hour are units, while milli and hecto are prefixes. A bare token resolves as a
unit; prefix interpretation requires attachment to a following prefixable
unit. Broader lexical ambiguity behavior remains the dedicated Phase 2
ambiguity task.

Authoritative sources are BIPM's SI Brochure 9th edition version 4.01
(CC BY 4.0), NIST SP 811 second printing (United States public information),
and IEC 80000-13:2025 for independently encoded factual information-unit and
binary-prefix definitions. No IEC text or tables are redistributed.

`GanitUnitAttributionGenerator` produces
`ThirdPartyNotices/UnitSources.md` from the runtime metadata. CI and the app
bundle builder reject drift, and the notice is copied into the signed app
resources.
