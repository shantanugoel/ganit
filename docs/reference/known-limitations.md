# Known limitations

What Ganit does not do yet, or does deliberately differently, as of the first
release candidate.

## Platform

- Apple silicon Macs only, macOS 14 or later.
- No iCloud or other sync. Sheets live in the app's container; see the
  [recovery guide](../storage/recovery-guide.md) to move them.
- No Settings window, Help book, or sharing menu. Options are menu items.

## Language and numbers

- Keywords and function names are English only. The engine supports locale
  separators, but new sheets use `en-US` separators until a locale preference
  exists.
- Roots other than perfect powers, logarithms, trigonometry, and constants
  such as `π` are approximate, computed with binary floating point and marked
  `≈`.
- Temperature differences have no syntax, so relative temperature arithmetic
  (`10 °C + 5 °C`) is unavailable.
- `pm` after a plain number is picometres; write `3:00 pm` for a time.

## Dates and time

- Gregorian calendar only, years 1 through 9999, whole seconds.
- Time-zone abbreviations such as `EST` or `IST` are rejected; use an IANA
  name or a listed city.
- Calendar arithmetic that lands in a daylight-saving gap moves past it, and
  in an overlap uses the earlier offset, without asking.

## Currency

- Only currencies in the ECB reference rates convert automatically; others
  need a manual rate such as `1 USD = 83 INR`.
- Rates update on ECB working days, are indicative, and are not for
  transactions.
- `$` and `¥` are ambiguous and must be written as `USD`, `US$`, `JPY`, and so
  on.
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
- Answers have not been compared side by side with Numi, Soulver, or Apple
  Math Notes.
- Performance has been measured on one development Mac, not on clean baseline
  hardware or against competitors.
- VoiceOver listening, right-to-left visual review, real IMEs, multiple
  physical displays, and Spaces are covered by automated structure checks
  only; see the [section 9 matrix](../quality/section-9-matrix.md).
