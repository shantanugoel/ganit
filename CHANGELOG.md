# Changelog

Notable changes to Ganit's behavior, especially anything that changes an
existing answer. See the [release train](docs/release/release-train.md).

## Unreleased

- Help ▸ Ganit Help opens a searchable reference of the grammar, functions,
  and keywords.
- Hovering a function, keyword, or error shows its signature or message;
  right-click opens Help or the interpretation card.
- About names Shantanu Goel and links to x.com/shantanugoel and the GitHub
  repository.
- Help ▸ Release Notes shows the changelog.
- Function and keyword names complete while typing. Edit ▸ Autocomplete turns
  that off.

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
