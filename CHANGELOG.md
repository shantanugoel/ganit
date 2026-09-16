# Changelog

Notable changes to Ganit's behavior, especially anything that changes an
existing answer. See the [release train](docs/release/release-train.md).

## Unreleased

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
