# Definitions

The definitions sheet holds the variables and units every sheet shares, so a
rate or a unit is written once and used everywhere. Window ▸ Definitions
(⌘⇧D) opens it.

```text
hourly rate = 90
1 bag = 25 kg
```

A sheet then reads both:

```text
hourly rate * 32
3 bags in kg
```

The definitions sheet is one text document, `Definitions.txt` beside the
library, not a library sheet: it is not listed, searched, exported, or backed
up, because it is vocabulary rather than a calculation of its own. It is a
sheet in every other way, with the same grammar, answers, diagnostics, and
editing. Its text is saved when its window stops being the key window, when
that window closes, and when Ganit quits, so a sheet never reads definitions
that are gone.

## What a sheet inherits

A definitions sheet exports every variable it declares successfully and every
unit it defines. Later declarations replace earlier ones of the same name, as
they do within a sheet.

Definitions stand above a sheet's first line:

- A sheet's own declaration of the same name replaces the shared one for the
  lines below it.
- A divider (`---`) resets a sheet's own declarations but keeps the shared
  ones, which no line can reach past.
- Nothing is inherited in the other direction: a sheet's declarations stay in
  that sheet.

Quick Ganit reads the definitions sheet like any other sheet.

## Custom units

`1 <name> = <quantity>` defines a unit as a multiple of an existing one, the
same form a [manual exchange rate](money-syntax.md) uses:

```text
1 bag = 25 kg
1 shift = 8 hours
```

A name beginning with `1` is never a variable, so nothing a person would write
as a name is taken for a definition. The name itself is one word that could
name a variable, so it cannot be a keyword, a constant, a function, a currency
code, or a unit a data source already names: `1 km = 5 m` fails with
`syntax.invalidVariableName`. A name also answers to its English plural when
that plural is free, so `3 bags` and `2 boxes` read naturally.

The value must be a relative quantity, which gives the unit its dimension and
its ratio to that dimension's canonical unit. Anything else fails with
`evaluation.invalidUnitDefinition` rather than defining nothing silently: a
plain number and an amount of money have no dimension, a temperature is
affine, and a calendar period such as `2 weeks` is counted in calendar days
rather than measured. A custom unit takes no SI or binary prefix: there is no
`kilobag`.

A custom unit converts and combines like any other unit of its dimension,
including in compound units, and `2 bags in liters` fails with
`evaluation.incompatibleDimensions`.

A definition line shows its own quantity as its answer, and the unit measures
for every line below it, in the sheet that defines it as well as in the
definitions sheet. A later definition can use an earlier one
(`1 pallet = 40 bags`), which stores its ratio rather than a reference, so
redefining `bag` afterwards does not change `pallet`. A unit is vocabulary
rather than an intermediate value, so a divider keeps it where it resets
variables.

## Attribution

A custom unit carries no data source. It is a person's own data, so it is
absent from the unit attribution notice, which lists only the factual
definitions Ganit encodes from published sources.
