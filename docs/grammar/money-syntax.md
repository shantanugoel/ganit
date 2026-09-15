# Money syntax

Money is an exact decimal amount of one ISO 4217 currency (`MoneyValue`).
Amounts never pass through binary floating point.

## Amounts

| Input | Value |
| --- | --- |
| `12.50 EUR`, `3 JPY` | an uppercase ISO 4217 code after a number |
| `€12.50`, `£3`, `₹(2 + 3)` | a symbol that names one currency |
| `US$5`, `C$5`, `A$5`, `HK$5`, `R$5` | a prefixed dollar sign |

`CurrencyCatalog` lists active ISO 4217 codes with their minor-unit digits;
fund, precious-metal, and testing codes are excluded. Codes are
case-sensitive and cannot be variable names. `$` and `¥` are used by several
currencies, so `$5` and `¥5` fail with `syntax.ambiguousCurrencySymbol` at
ambiguity severity; the locale never picks one.

## Arithmetic

- money ± money of the same currency → money;
- money × number, number × money, money ÷ number → money;
- money ÷ money of the same currency → number;
- money ± percentage, percentage × money, and percentage phrases
  (`20% of 50 EUR`, `10% off 20 EUR`) → money;
- percentage ratio and change phrases between amounts of one currency →
  percentage.

Amounts in different currencies never combine: `10 EUR + 1 USD` fails with
`evaluation.mixedCurrencies`. Money plus a bare number is a type mismatch.

## Conversion

`in`, `to`, `as`, or `into` followed by a currency code converts money:
`100 USD in EUR`. The rate is exact rational arithmetic on the context's
`CurrencyRates`, units per euro from one ECB snapshot: a direct euro rate, or
a cross rate divided from two euro rates. A currency without a rate fails with
`evaluation.missingCurrencyRate`.

## Manual rates

A line `1 USD = 83.25 INR` declares a manual rate. It is visible to the lines
below until a divider, like a variable, and overrides reference rates for that
pair in both directions: `100 USD in INR` is `8325 INR` and `8325 INR in USD`
is `100 USD`. The right side must be a positive amount of another currency;
otherwise the line fails with `evaluation.invalidCurrencyRate`. Editing a
manual rate re-evaluates only lines that name one of its currencies. The same
`1 x = …` form defines a [custom unit](definitions.md) when `x` is not a
currency code.

## Display

Results are shown in the locale's currency style rounded half away from zero to
the currency's minor units, marked `≈` when rounding changed the amount. Full
precision keeps the exact amount and the code: `100/3 USD`.

## Provenance and freshness

Each line records the kinds of rate its conversions used
(`SheetLineResult.rateUses`), and the answer details describe them:

- **Exchange rate:** `ECB reference rate` for a direct euro rate,
  `Calculated by Ganit from ECB reference rates` for a cross rate, and
  `Manual rate` for a declared rate.
- For reference and cross rates: **Source** `ECB statistics`, **Rates
  published** (the ECB observation date), **Retrieved**, **Rate status**, and
  **Note** `Indicative, not for transactions`.

Rate status compares the observation date with the current calendar day in the
sheet's time zone (`RateFreshness`): `Current` on the publication day,
`Weekend rates, N days old` when every day since is a Saturday or Sunday,
`N days old` otherwise, and `Stale, N days old` once more than four days have
passed. Status uses the time the details are shown, so it ages while a sheet
stays open.

Without any downloaded rates, a conversion that has no manual rate fails with
`evaluation.currencyRatesUnavailable`, which suggests declaring one; a
currency missing from downloaded rates fails with
`evaluation.missingCurrencyRate`.
