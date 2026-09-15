# Problem reports

Ganit never uploads anything about a user's sheets. **Help ▸ Report a
Problem…** writes a plain-text report the user saves, reads, and sends however
they choose.

A report (`ProblemReport`) contains:

- a prompt for what the user did, expected, and saw;
- the app version and build, macOS version, and Mac model identifier;
- the number of sheets, whether exchange rates update automatically, the
  published date of the rates in use, and whether Spotlight titles and an
  empty Quick Ganit are on;
- the frontmost sheet's text only when the user ticks **Include the current
  sheet's text**, otherwise `(not included)`.

It holds no titles, file paths, account, or device identifiers beyond the
model. `ProblemReportTests` pins the format, including that sheet text is
absent unless included.

Beta testers send reports and describe problems through whatever channel the
beta uses; recruiting testers is outside the app.
