# Changelog

Notable changes to Ganit's behavior, especially anything that changes an
existing answer. See the [release train](docs/release/release-train.md).

## Unreleased

- Format ▸ Markdown Mode (formerly Prose Mode) writes answers in the lines,
  treats sentences as paragraphs, and is also on a sheet's right-click menu.
  Markdown sheets show a document mark in the sidebar. `=>` ends a calculation.
- The menu bar icon's menu has Show Window, which brings the current window
  forward instead of opening another.
- `$` is USD unless Format ▸ Dollar Means or a sheet's right-click menu picks
  another dollar currency. `USD 1.5`, `5 dollars`, `¥5`, and scale words such
  as `11.5 million` / `11.5mn` / `3k` parse as everyday amounts. Ambiguity
  registry version 6.

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
