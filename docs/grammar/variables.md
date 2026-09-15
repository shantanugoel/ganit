# Variables

A calculation line may declare a variable:

```text
monthly rent = 2,100
months = 12
Yearly: monthly rent * months
```

## Names

A name is one or more identifier words separated by whitespace. Whitespace
between words is normalized, so `monthly   rent` refers to `monthly rent`.
Names are case-sensitive and compare Unicode canonical equivalents as equal.

A word cannot be a grammar keyword (`in`, `to`, `as`, `into`, `of`, `off`, `on`,
`is`, `what`, `after`, `percentage`, `change`, `from`), a constant (`pi`, `π`,
`e`), a built-in function name, or a unit alias including prefixed forms. A
colliding or non-word name, such as `km = 5` or `2x = 1`, fails with
`syntax.invalidVariableName` and declares nothing.

In an expression, adjacent identifier words resolve to the longest declared
name that they begin. Otherwise each identifier is resolved alone.

## Scope

Lines are evaluated from top to bottom. A declaration is visible to later lines
only, which prevents cycles. Redeclaring a name replaces its value for lines
below, and the right-hand side may use the previous value: `tax = tax + 2%`.
A divider (`---`) resets scope; headings do not.

Using a name before it is declared fails with `evaluation.unknownIdentifier`.
Using a variable whose declaration failed reports
`evaluation.unavailableVariable` at the use rather than an unrelated value.

The parser receives each visible variable's value kind, so a percentage
variable participates in percentage phrases (`tax of 50`) and a quantity
variable in conversions (`trip distance in miles`).
