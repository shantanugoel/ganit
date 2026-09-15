# Temporal values

Ganit keeps five kinds of time value distinct, so a calendar month is never
silently treated as a number of seconds.

| Value | Type | Example display | Full precision |
| --- | --- | --- | --- |
| Date | `DateValue` | Feb 29, 2024 | `2024-02-29` |
| Time of day | `LocalTimeValue` | 2:05 PM | `14:05:00` |
| Instant | `InstantValue` | Mar 9, 2024 at 12:00 PM America/New_York | `2024-03-09T12:00:00-05:00[America/New_York]` |
| Calendar period | `CalendarPeriodValue` | 1 year, 2 months, 3 days | `P1Y2M3D` |
| Duration | `QuantityValue` of time | 90 min | `90 min` |

Dates are proleptic Gregorian dates in years 1 through 9999. Times of day
have whole-second resolution. Instants are absolute moments shown in a named
IANA zone. A calendar period holds whole months and whole days; weeks are
seven days, quarters three months, and years twelve months. Durations are the
existing time quantities (`s`, `min`, `h`).

Period literals are a whole count followed by `day`, `week`, `month`,
`quarter`, or `year`, singular or plural: `3 months`, `2 weeks`. A fractional
count such as `1.5 months` is an error, because half a month has no fixed
length. A declared variable such as `months = 12` shadows the period word
below its declaration.

## Arithmetic

`TemporalArithmetic` applies before ordinary arithmetic:

- date ± period → date, adding months before days and clamping to the end of
  a shorter month (`Jan 31 + 1 month` is `Feb 29` in 2024);
- date − date → period of days;
- time ± duration → time, wrapping around midnight; the duration must be a
  whole number of seconds;
- time − time and instant − instant → duration, in hours or minutes when the
  result is a whole number of them and in seconds otherwise;
- instant ± duration → instant, shifting by elapsed time;
- instant ± period → instant, keeping the wall-clock time in the instant's
  zone, so `1 day` across a daylight-saving change can be 23 or 25 hours;
- period ± period → period, period × whole number → period, and −period.

Periods and durations never mix: `1 month + 30 min` and `time + 1 day` are type
mismatches. Results outside the supported date range report
`evaluation.dateOutOfRange`.
