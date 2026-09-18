# Known limitations

What Ganit does not do yet, or does deliberately differently, as of the first
release candidate.

## Platform

- Apple silicon Macs only, macOS 14 or later.
- No iCloud or other sync. Sheets live in the app's container; see the
  [recovery guide](../storage/recovery-guide.md) to move them.
- No sharing menu. Help is an in-app searchable reference rather than a Help
  book.

## Language and numbers

- Keywords and function names are English only. A sheet writes numbers either
  `1,234.56` or, with Format ▸ Decimal Comma, `1.234,56`; other separators,
  such as a space for grouping, are not offered. A line written in the other
  style is diagnosed with a rewrite rather than sent to the assistant.
- An exact answer is shown to the sheet's significant digits or decimals, and
  money to its currency's minor units. An answer marked `≈` was rounded to be
  shown, so `1/3` reads `≈ 0.333333333333333`; its interpretation card says
  the value is exact and rounded by Format ▸ Number Format. Copy Full
  Precision, and the CSV Full Precision column, give the exact value.
- Roots other than perfect powers, logarithms, trigonometry, and constants
  such as `π` are approximate, computed with binary floating point and marked
  `≈`.
- Temperature differences have no syntax, so relative temperature arithmetic
  (`10 °C + 5 °C`) is unavailable.
- `pm` after a plain number is picometres; write `3:00 pm` for a time.
- No phrase rounds a single answer, such as `1/3 to 2 dp`; write `round(1/3, 2)`,
  or choose the answer's own format from its right-click Answer Format menu.
  That choice is kept with the sheet by the line's text, so editing the line
  returns it to the sheet's Format ▸ Number Format.
- There is no `irr`: a rate that solves a cash flow needs an iterative search
  whose starting guess and convergence rule the answer would depend on. `npv`
  discounts a flow at a rate you give.
- A percentage and a bare number do not add (`50% + 0.5`), because the
  intended meaning is not knowable.

## Dates and time

- Gregorian calendar only, years 1 through 9999, whole seconds.
- Time-zone abbreviations such as `EST` or `IST` are rejected; use an IANA
  name or a listed city.
- Calendar arithmetic that lands in a daylight-saving gap moves past it, and
  in an overlap uses the earlier offset, without asking.
- A calendar day is not a fixed number of hours, so `1 day in hours` fails;
  `24 h in min` and other fixed-duration conversions work.

## Currency

- Only currencies in the ECB reference rates convert automatically; others
  need a manual rate such as `1 USD = 83 INR`.
- Rates update on ECB working days, are indicative, and are not for
  transactions.
- `$` means the sheet's dollar currency, USD unless Format ▸ Dollar Means picks
  another, and `¥` means JPY. Write a code such as `SGD` or a symbol such as
  `S$` for any other dollar or yen.
- Finance functions (`fv`, `pv`, `pmt`) use one rate per period, compounding
  once per period, with payments at the end of each period.

## Integrations

- The Shortcuts action, service, `ganit://` URL, and `ganit` command answer
  one expression or sheet; they cannot open, create, or change sheets.
- The `ganit` command reads the app's stored exchange rates but not the
  definitions sheet.
- Quick Look previews exist only for exported `.ganit` packages.
- Spotlight indexes sheet titles only, when turned on.

## Not yet verified

- Task-based usability sessions with novices and Numi or Soulver users have
  not been run.
- Answers have not been compared with Apple Math Notes, which has no
  scriptable interface. Numi and Soulver are covered by the
  [answer comparison](../quality/compatibility.md).
- Performance has been measured on one development Mac, not on clean baseline
  hardware. Numi is compared as an engine and on memory and bundle size; its
  launch and typing latency need a person, because it puts no window on screen
  until someone opens it. See the
  [performance methodology](../public/performance-methodology.md).
- VoiceOver listening, right-to-left visual review, real IMEs, multiple
  physical displays, and Spaces are covered by automated structure checks
  only; see the [section 9 matrix](../quality/section-9-matrix.md).
