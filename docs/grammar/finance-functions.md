# Finance functions

Three functions name the compounding arithmetic behind a loan or a savings
balance, so a sheet can say what it means instead of repeating the formula:

| Form | Meaning |
|---|---|
| `fv(amount, rate, periods)` | what `amount` grows to: `amount × (1 + rate)^periods` |
| `pv(amount, rate, periods)` | what a later `amount` is worth now: `amount ÷ (1 + rate)^periods` |
| `pmt(amount, rate, periods)` | the equal payment that repays `amount`: `amount × rate ÷ (1 − (1 + rate)^−periods)` |

```text
Balance: fv(10,000 USD, 5%, 10)
Monthly: pmt(300,000 USD, 0.5%, 360)
```

They are ordinary functions of their arguments, with no hidden table, market
data, or regulatory rounding. Ganit shows the assumptions each one makes rather
than leaving them to be guessed, and gives no financial advice.

## Arguments

- `amount` is money or a plain number, and the answer keeps its kind, so money
  stays in its currency. A percentage, quantity, or date fails with
  `evaluation.typeMismatch`.
- `rate` is the rate for **one period**, as a percentage (`0.5%`) or the
  fraction it stands for (`0.005`). An annual rate over monthly periods is the
  caller's own division: `pmt(300,000 USD, 6% / 12, 360)`.
- `periods` is a whole number of periods, at least one. A fraction of a period
  would compound by a rule nobody stated, so `fv(1000, 5%, 1.5)` fails with
  `evaluation.invalidDomain`, as do zero and negative counts.
- `pmt` with a rate of zero repays the amount in equal parts.

`fv`, `pv`, and `pmt` are function names, so they cannot also be variable
names, and a name such as `pmt = 5` fails with `syntax.invalidVariableName`.

## Exactness and assumptions

Compounding a decimal rate over whole periods is exact arithmetic, so results
stay exact and only display rounds them: `fv(1000, 10%, 2)` is `1,210`, and a
money answer rounds to its currency's minor units with `≈` when rounding
changed it. Full precision keeps the exact amount.

The [interpretation card](../editor/text-view.md) lists what the answer
assumed, one row per function used:

| Function | Assumption |
|---|---|
| `fv` | The rate is per period and compounds once each period. |
| `pv` | The rate is per period and discounts once each period. |
| `pmt` | Equal payments at the end of each period, at the rate for one period. |
