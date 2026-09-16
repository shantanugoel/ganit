# Changelog

Notable changes to Ganit's behavior, especially anything that changes an
existing answer. See the [release train](docs/release/release-train.md).

## Unreleased

- In Markdown Mode, a line with a spaced `+`, `*`, `/`, `^`, or `=` that does
  not calculate shows its problem instead of quietly becoming a paragraph.
- Numbers at or above `1e21` or below `1e-6` show as a power of ten:
  `1e100` and `6.674e-11` instead of a hundred digits or a row of zeroes.
  `2^64` still shows every digit, and Copy Full Precision copies the exact value.
- `€40 + $10` adds the dollars in euros at the day's rates, and
  `€40 + $10 in USD` converts the total. `$10 in EUR` no longer reads `in` as
  inches, and a manual rate such as `1 USD = 83 INR` applies to amounts written
  with symbols.
- Fuel economy: `mpg`, and conversion targets per a count of a unit such as
  `L/100 km`. Reciprocal units convert either way up: `35 mpg in L/100 km` is
  `6.72041666666667 L/100 km`.
- A time of day converts to another zone: `3:00 pm in Tokyo` is 3 pm today
  here, shown in Tokyo.
- Mixed units add: `5 ft 10 in in cm` is `177.8 cm` and `2 h 30 min in min` is
  `150 min`. Ambiguity registry version 7.
- Knots and nautical miles, and area and volume words: `1200 sq ft in sq m`,
  `2 cubic m in L`, `1 knot in km/h`.
- Electrical units: amperes, volts, ohms (`Ω` or `ohm`), farads, henries,
  coulombs, ampere-hours, and hertz, with prefixes such as `mA`, `kΩ`, `nF`,
  `mAh`, and `MHz`; plus horsepower and electronvolts. `5 V / 220 Ω in mA` is
  `22.7272727272727 mA`. `A`, `V`, `C`, `F`, and `H` can no longer name a
  variable.
- Prices per unit: `$0.15/kWh * 45 kWh` is `$6.75`, `₹8/kWh * 1,245 kWh` and
  `1500 W * 3 h * 30 * 0.15 USD/kWh` work, and `$30 / 2 kWh` is `$15.00/kWh`.
- `sum`, `average`, `line N`, and a variable that read a failed line say which:
  `Line 12 has an error, so this cannot use it.`
- `sin`, `cos`, and `tan` take an angle with its unit: `sin(30°)` is `0.5` and
  `cos(1 rad)` works whatever the angle mode.
- `16/09/2026` and `09/16/2026` say to write a date as `2026-09-16` or
  `16 Sep 2026` instead of silently dividing. Spaced slashes still divide.
- `2 ** 10` is a power, `1,024`. A stray word inside parentheses, such as
  `(5 V - 2 V)`, is reported where it is instead of as a missing `)`, and
  `(2 m)^0.5` says a unit takes only a whole power instead of calling the
  exponent too large.
- A failed line's interpretation card shows Where: the underlined text the
  problem is at. It no longer shows the internal diagnostic code, and the
  right-click menu lists Show Interpretation once.
- `line N` keeps naming the same line when lines are added or removed above it:
  the editor rewrites the number in the same undoable edit, instead of the
  reference silently reading a different line.
- `as %`, `in %`, `to %`, and `into %` show a ratio as a percentage:
  `savings / salary as %` is `40.6666666666667%`.
- Lakh grouping reads as a number: `1,00,000 + 5,00,000` is `600,000`, and
  `pmt(₹50,00,000, 8.5% / 12, 240)` no longer splits the amount into
  arguments. Format ▸ Group Digits in Lakhs writes a sheet's answers as
  `12,34,567`.
- `total`, `sum`, `count`, `average`, `median`, `previous`, and their short forms
  can name a variable, so `total = price * qty` works; below it the word means
  the variable. A name that is still taken, such as `min wage`, marks the
  taken word and says to choose another name. Ambiguity registry version 7.
- Exact decimal answers show at most the sheet's significant digits and no
  trailing zeroes: `100 * 1.25` is `125`, not `125.00`, and `10000 * 1.05^10`
  is `16,288.9462677744`, not 26 digits ending in zeroes. Copy Full Precision
  still copies the exact value.
- The assistant no longer shows a line of a model's reasoning, such as "End of
  thought process", or bare punctuation as an answer. Reasoning counts only
  when it holds the JSON value Ganit asked for.
- Quick Ganit hides when one of Ganit's own windows comes forward, instead of
  floating over its answers. It still floats over other apps.
- Quick Ganit selects the text it kept from last time when it opens, so typing
  replaces it instead of joining it into a different calculation.
- Return ends a line even when a completion is showing, so `5 min` or `2 m`
  no longer turns into `min(x, y)` or `max(…)`. Tab or a click inserts a
  completion, and Return does after an arrow key picks one.
- Hovering an answer, error, or function shows its text again instead of the
  editor's internal description.

## 0.2.2

- An assistant address is any OpenAI-compatible base (`https://api.openai.com/v1`,
  `http://localhost:…/v1`, `https://host/v1`, or a host with no path). Ganit
  POSTs `chat/completions` under it. The full `.../v1/chat/completions` path
  still works.
- While an assistant reply is in flight the sheet stays editable and shows
  Asking… instead of the red diagnostic. Replies are requested as JSON and
  stripped of think-tags and wrapping so a local model can still yield a short
  value. The wait is long enough for a model that is still loading.
- Change Answer…, on a line's right-click menu and under Calculate, replaces
  an assistant value with text you type.
- Ask Assistant, on a line's right-click menu and under Calculate, asks again
  about a line Ganit could not work out, or an `ask_assistant` prompt.
- Copy with Results copies each selected line with the answer that line shows.
- Copy Result copies a failure's message when that is what the column shows.
- Hovering a truncated answer or error in the result column shows the full
  text.
- Help ▸ Ganit Help opens the in-app reference instead of reporting that Help
  isn't available.

## 0.2.1

- Format ▸ Markdown Mode (formerly Prose Mode) writes answers in the lines,
  treats sentences as paragraphs, and is also on a sheet's right-click menu.
  Markdown sheets show a document mark in the sidebar. `=>` ends a calculation.
- The menu bar icon's menu has Show Window, which brings the current window
  forward instead of opening another.
- `$` is USD unless Format ▸ Dollar Means or a sheet's right-click menu picks
  another dollar currency. `USD 1.5`, `5 dollars`, `¥5`, and scale words such
  as `11.5 million` / `11.5mn` / `3k` parse as everyday amounts. Codes, names,
  symbols, and units may sit before or after the number. Ambiguity registry
  version 6.
- The menu bar and the sheet's right-click menu list only Ganit commands;
  Services, the second Print, and AppKit Font/Spelling/Speech items are gone.
- Help lists topics on the left and shows the selected topic on the right.
- The Dock and Finder icon is the same `function` mark as the menu bar.
- Completions show function parameters (`sqrt(x)`, `round(x, places)`).
  Inserting one selects the first parameter; Tab selects the next.
- Clicking a completion inserts it. The list is as wide as the longest
  signature. Markdown sheet titles truncate so the document mark stays in the
  sidebar. Help’s topic list holds its column and the page wraps beside it.
- Nested parentheses no longer trap the sheet calculator in debug builds.

## 0.2.0

- Help ▸ Ganit Help opens a searchable reference of the grammar, functions,
  and keywords.
- Hovering a function, keyword, or error shows its signature or message;
  right-click opens Help or the interpretation card.
- About names Shantanu Goel and links to x.com/shantanugoel and the GitHub
  repository.
- Help ▸ Release Notes shows the changelog.
- Function and keyword names complete while typing. Edit ▸ Autocomplete turns
  that off.
- Ganit ▸ Settings… gathers the app-wide switches in one window.
- A short tour runs the first time Ganit opens a sheet. Skip dismisses it;
  Settings and Help ▸ Show Tour open it again.
- `round(x, n)` keeps `n` digits after the decimal, including trailing zeroes.
- `log2`, `cbrt`, `trunc`, `sign`, `atan2`, `hypot`, `clamp`, `fact`, and `mod`
  cover the usual scientific-calculator functions Soulver and similar apps
  offer, without postfix `!`.
- `ask_assistant(prompt)` and `prompt_assistant(prompt)` send the prompt to a
  configured assistant and use the reply as a value later lines can calculate
  with.

## 0.1.1

- Ganit can install its own updates. It looks for one only when asked, either
  by choosing Check for Updates… or by ticking Check for Updates
  Automatically, which a fresh copy leaves unticked. Copies of 0.1.0 cannot
  update themselves and have to be replaced by hand, once.

## 0.1.0

First release.

- Calculations with exact numbers, percentages, units, variables, references,
  dates and time zones, money with ECB and manual exchange rates, and finance
  functions.
- Sheets with autosave, daily backups, folders, search, export to `.ganit`,
  text, PDF, CSV, and HTML, printing, and Quick Look previews.
- Quick Ganit, the Evaluate Expression service, the Calculate Expression
  shortcut, `ganit://` links, the `ganit` command, and optional Spotlight
  titles.
- Ambiguity registry version 5; answers pinned by the golden corpus.
