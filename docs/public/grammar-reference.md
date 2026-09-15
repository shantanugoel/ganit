# Grammar reference

Ganit reads each line as a calculation, heading, comment, or divider. Answers
appear beside the line.

| Topic | Examples | Reference |
| --- | --- | --- |
| Lines, labels, comments, dividers | `Rent: 2,100 // shared`, `# Trip`, `---` | [Line syntax](../grammar/line-syntax.md) |
| Arithmetic and functions | `(2 + 3) * 4`, `sqrt(2)`, `0xff`, `2^10` | [Arithmetic](../grammar/arithmetic-syntax.md) |
| Percentages | `20% off 85`, `15 is what % of 60`, `85 + 20%` | [Percentages](../grammar/percentage-syntax.md) |
| Units | `12 km in miles`, `75 MB/s * 2 s`, `0 °C as °F` | [Units](../grammar/unit-syntax.md) |
| Variables | `monthly rent = 2,100`, `monthly rent * 12` | [Variables](../grammar/variables.md) |
| References and totals | `line 2 * 3`, `previous`, `sum`, `subtotal` | [References](../grammar/references.md) |
| Shared definitions | `hourly rate = 90`, `1 bag = 25 kg` | [Definitions](../grammar/definitions.md) |
| Dates and times | `today + 3 months`, `2024-03-09T12:00 Europe/London`, `now in Tokyo` | [Dates and time](../grammar/date-syntax.md) |
| Money and exchange rates | `12.50 EUR`, `€5`, `100 USD in INR`, `1 USD = 83 INR` | [Money](../grammar/money-syntax.md) |
| Finance | `pmt(300,000 USD, 6% / 12, 360)` | [Finance functions](../grammar/finance-functions.md) |
| How ambiguity is resolved | `in` as inches or conversion, `$5`, `2024-03-09` | [Ambiguity registry](../grammar/ambiguity-registry.md) |

When Ganit cannot pick one meaning, it says so with a message and, where it
can, suggestions, instead of guessing. The [known limitations](../reference/known-limitations.md)
list what the grammar does not cover.
