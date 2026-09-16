# Date and time syntax

Dates, times, and instants are written in ISO 8601 form or as common English
phrases. They evaluate to the [temporal values](../engine/temporal-values.md)
and resolve relative words against the evaluation context's frozen `now` and
time zone.

## ISO input

| Input | Value |
| --- | --- |
| `2024-03-09` | date |
| `9:05`, `14:05:30` | time of day |
| `3:30 pm`, `12:15 AM` | time of day, 12-hour |
| `2024-03-09T12:00` | instant at that wall-clock time in the evaluation zone |
| `2024-03-09T12:00Z`, `2024-03-09T12:00-05:00` | instant at that UTC offset |

A date needs four-digit years and two-digit months and days; `2024-3-9` stays
subtraction. Fields are checked when evaluated, so `2023-02-29` reports
`evaluation.invalidDate` and `24:00` reports `evaluation.invalidTime`.

## English phrases

| Phrase | Value |
| --- | --- |
| `today`, `tomorrow`, `yesterday` | date in the evaluation zone |
| `now` | instant in the evaluation zone |
| `next friday`, `last mon` | the weekday strictly after or before today |
| `March 9, 2024`, `mar 9 2024`, `9 March 2024` | date |
| `Dec 25`, `25 Dec` | date in the current year |
| `3 days ago`, `2 weeks from now` | today moved by a calendar period |
| `90 min ago`, `2 h from now` | now moved by a duration |

Month and weekday names accept full names and common abbreviations, in any
letter case. `ago` and `from now` apply to the whole expression before them:
`1 month + 2 weeks from now` moves today by six weeks and a month.

## Time zones

`in`, `to`, `as`, or `into` followed by a zone shows an instant in that zone,
and a zone after an ISO date and time without an offset places its wall-clock
time there. A time of day alone is that time today in the sheet's zone:

```text
now in Asia/Tokyo
3:00 pm in Tokyo
2024-03-09T17:00Z in New York
2024-03-09T12:00 Europe/London
```

A zone is an IANA identifier in any letter case, such as `Asia/Tokyo` or
`America/Argentina/Buenos_Aires`, or one of a small set of city aliases for
large cities in exactly one zone, such as `Tokyo`, `New York`, or `Mumbai`
(see `TimeZoneNames.aliases`). Abbreviations such as `EST`, `IST`, and `CST`
are rejected with `syntax.unknownTimeZone`, because each names several offsets
or regions. `UTC` and `GMT` are accepted. The result keeps the zone's
identifier, and full precision shows the resolved offset:
`2023-11-15T07:13:20+09:00[Asia/Tokyo]`.

## Daylight-saving changes

A wall-clock time in a zone, including the evaluation zone, must name exactly
one instant:

- A time skipped when clocks move forward, such as
  `2024-03-10T02:30 America/New_York`, fails with
  `evaluation.nonexistentLocalTime`. Its fix-it moves the time past the gap:
  `2024-03-10T03:30:00-04:00 America/New_York`.
- A time repeated when clocks move back, such as
  `2024-11-03T01:30 America/New_York`, is reported with ambiguity severity as
  `evaluation.ambiguousLocalTime`. Its two fix-its add each offset, earlier
  first.
- An offset and a zone together pick one instant, as in
  `2024-11-03T01:30-05:00 America/New_York`. An offset the zone does not use
  at that time fails with `evaluation.offsetMismatch`.

The interpretation card lists the fix-its as suggestions and shows every
instant's time zone and UTC offset. Calendar arithmetic on instants does not
ask: adding a period that lands in a gap moves past it, and one that lands in
an overlap uses the earlier offset.

## Keywords

`today`, `tomorrow`, `yesterday`, `now`, and `ago` are keywords. Month names,
weekday names, `next`, `last`, and period words may be declared as variables,
and a declared variable is used in place of the phrase. See the
[ambiguity registry](ambiguity-registry.md#dates--date-and-time-input-versus-arithmetic-and-units).
