# Dimensionally typed rates

`RateValue` keeps a scalar or percentage amount separate from its denominator,
supporting values such as `60/hour` and `6.5%/year` without flattening
percentages. Money can become another amount case when its value model is
introduced. Ordinary physical rates such as `75 MB/s` use the canonical
`QuantityValue` compound-unit representation, avoiding two unequal values that
format identically.

Fixed-unit denominators use a ratio `UnitExpression`. Their dimensions are
validated when a rate is converted or applied. For example, `60/hour`
converts exactly to `1/minute`, and applying `75 MB/s` to `2 s` produces
`150 MB`. Bare period counts apply only to calendar rates.

Month, quarter, and year are calendar rate periods rather than guessed fixed
durations. Calendar rates convert by exact month counts (`1 year = 12 months`
for rate-frequency normalization), but cannot convert to seconds or be applied
to a fixed-duration quantity without future calendar semantics. This prevents
silently treating a financial year as 365 or 365.25 days.

Affine units cannot be denominators. This prevents offsets such as Celsius
from entering multiplicative rate algebra. Compound denominators are
parenthesized in formatted output, and calendar period labels are localized
for display while canonical output retains stable English labels.
