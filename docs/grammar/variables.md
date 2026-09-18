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
Names match whatever their letter case, so `Rent`, `rent`, and `RENT` are one
variable, and they compare Unicode canonical equivalents as equal. Units and
function names keep their case, because `M` and `m` are different units.

A word cannot be a grammar keyword (`in`, `to`, `as`, `into`, `of`, `off`, `on`,
`is`, `what`, `after`, `percentage`, `change`, `from`, `today`, `tomorrow`,
`yesterday`, `now`, `ago`), a constant (`pi`, `π`,
`e`), a built-in function name, a unit alias including prefixed forms, or an
ISO 4217 currency code such as `USD`. A
colliding or non-word name, such as `km = 5` or `2x = 1`, fails with
`syntax.invalidVariableName`, marks the word that is taken, and declares
nothing. A name that is not words at all, such as `Groceries (Costco) = 230`,
fails with `syntax.nonWordName` and says to write words or a label ending in a
colon. A reference keyword such as `total` or `count` may be a name; below
the declaration it means the variable. `line` alone may not.

In an expression, adjacent identifier words resolve to the longest declared
name that they begin. Otherwise each identifier is resolved alone.

## Scope

Lines are evaluated from top to bottom. A declaration is visible to later lines
only, which prevents cycles. Redeclaring a name replaces its value for lines
below, and the right-hand side may use the previous value: `tax = tax + 2%`.
A divider (`---`) resets scope; headings do not. The
[definitions sheet](definitions.md)'s declarations stand above the first line,
so a sheet's own declaration of the same name replaces one, and a divider
keeps them.

Using a name before it is declared fails with `evaluation.unknownIdentifier`.
Using a variable whose declaration failed reports
`evaluation.unavailableReference` at the use rather than an unrelated value.

The parser receives each visible variable's value kind, so a percentage
variable participates in percentage phrases (`tax of 50`) and a quantity
variable in conversions (`trip distance in miles`).
