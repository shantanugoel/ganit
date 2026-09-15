# Ganit — Product and Implementation Plan

> A native macOS thinking calculator: as immediate as a scratchpad, as trustworthy as a well-tested numerical library, and as calm as a great writing app.

**Status:** Greenfield plan
**Research cutoff:** 2026-09-14
**Repository state when written:** Empty, not yet initialized as Git
**Working product name:** Ganit
**Primary platform:** macOS 14+; progressively adopt newer macOS design APIs behind availability checks

---

## 1. Product decision

Build an AppKit-first, local-first macOS application with two surfaces backed by one deterministic calculation engine:

1. **Quick Ganit** — a global-hotkey scratchpad that appears focused, calculates immediately, copies a result, and disappears.
2. **Ganit Workspace** — a persistent, multi-line calculation notebook with a Notes-like sheet library, live aligned answers, variables, references, totals, search, and robust export/backups.

The source text is always the user's visible source of truth. Answers are deterministic, typed, explainable, and produced locally. Natural language is a compact grammar, not an AI chat interface. Live data is narrowly limited to explicit, cached datasets such as exchange rates; every such result shows provider and observation time.

The winning promise is not “every conceivable feature.” It is:

> **The fastest trustworthy numerical scratchpad for Mac.**

### 1.1 Non-negotiable product principles

1. **Instant by default.** Launch, focus, typing, evaluation, and copy must feel immediate.
2. **Correct before clever.** Never guess silently. Reject, clarify, or visibly mark assumptions.
3. **Simple first frame.** A new user sees a text cursor and useful examples—not modes, palettes, or a keypad.
4. **Power through composition.** Advanced behavior comes from ordinary lines, variables, references, units, and commands rather than separate mini-apps.
5. **Text remains text.** Standard selection, IME input, copy/paste, Find, undo, drag, Services, and accessibility must work.
6. **Local and private.** Core calculation requires no account, permission, telemetry, or network.
7. **Native Mac behavior.** Standard windows, menus, shortcuts, toolbar/sidebar behavior, Settings, Help, VoiceOver, restoration, and document actions.
8. **Measured efficiency.** Performance and footprint are release gates, not marketing adjectives.
9. **Progressive disclosure.** Advanced detail appears only when useful, but every command remains discoverable in menus and Help.
10. **Durable work.** Atomic saves, recoverable plain text, versioned formats, backups, and tested migrations.

### 1.2 What “best” means

Ganit succeeds when it wins on the combined experience, not on the longest checklist:

- Numi-like compactness and low-friction natural input.
- Soulver-like durable sheets, references, variables, totals, and Mac integration.
- Better ambiguity handling and provenance than either.
- Better measured launch, typing, idle-resource, and large-sheet behavior.
- Better failure UX: an invalid or ambiguous line explains itself and never masquerades as a valid result.
- Better data durability: local-first storage, atomic writes, visible backups, and conflict-safe optional sync.
- Less feature anxiety: one consistent grammar and no “baroque” collection of hidden special workflows.

---

## 2. Evidence and lessons from the market

### 2.1 Numi

Verified current documentation describes:

- Natural-language arithmetic and unit/currency conversion.
- Percent phrases, variables, constants, scientific functions, programmer literals, date/time and time-zone operations.
- Previous-result, sum/total, and average tokens.
- Headings, comments, labels, import/export using UTF-8 plain text, an Alfred workflow, a CLI, and JavaScript extensions.
- Multiple parser languages.

What people like:

- Minimal, attractive single-editor interface.
- Keyboard-first speed and quick invocation.
- Consecutive calculations with a visible record.
- Input that resembles how people informally think about quantities.

Observed weaknesses/opportunities:

- Format sensitivity and silent or confusing parser misses.
- Reports of variable, date-difference, unit, and stale-rate issues.
- Maintenance confidence: the latest verified Mac build remains 3.32.721 from April 2023 while users have questioned whether it is abandoned.
- A 2025 privacy policy permits technical and usage analytics; Ganit can make no calculation text leaving the Mac the default and verifiable behavior.

### 2.2 Soulver

Soulver 4 is the feature and native-experience benchmark:

- Live answers beside a persistent line-oriented editor.
- Notes-like sheets, folders, pin/archive/trash/search, separate windows, autosave and backups.
- Multi-word variables, upward references, reactive recalculation, global definitions and custom units.
- Totals, averages, count, median, subtotals, headings, comments, dividers, labels, highlighting, and tags.
- Broad arithmetic, units, currencies, dates/times/time zones, financial/scientific/programmer functions and several specialized workflows.
- QuickSoulver, Services, Shortcuts, URL schemes, Spotlight, Quick Look, CLI, Alfred/Raycast, and extensive export/sharing.
- On-device deterministic core; no AI is required for ordinary calculation.

What people like:

- The “calculator + scratchpad + lightweight spreadsheet” combination.
- Context around numbers, editable what-if work, and avoiding a full spreadsheet.
- Fast unit/date/currency questions and durable project calculations.
- Native fit and broad keyboard/automation support.

Observed weaknesses/opportunities:

- Feature breadth can feel overwhelming; some advanced workflows break the simple freeform model.
- Historical iCloud sync lag/data-loss reports. Soulver 4 redesigned sync, but independent post-v4 reliability evidence is not yet sufficient.
- Specialized inputs can fail without explaining why; a city lookup example silently missed before a later fix.
- No public controlled benchmarks for latency, memory, energy, or large-sheet scaling.
- A current App Store review reports compound-unit regression in Soulver 3 versus Soulver 2. Ganit must make dimensional algebra a tested core invariant.

### 2.3 Nearby products and the macOS baseline

- Apple Calculator and Math Notes make history, conversions, inline math, and variables free baseline features. Deliberate invocation and predictable non-invasive behavior remain differentiation.
- Parsify validates interest in extensibility, but its 84–88 MB desktop downloads and stale/open parser issues show the embedded-web-runtime and silent-failure traps.
- Qalculate defines a power/correctness ceiling but carries broad CAS complexity and a non-native UI/dependency footprint.
- SpeedCrunch validates keyboard-first speed, but its documented silent representation downgrade is explicitly unacceptable.
- Calca validates offline calculations embedded in prose but has uncertain current Mac maintenance.

### 2.4 Product conclusions

Adopt:

- Live aligned results.
- Persistent editable text.
- Quick and durable workflows.
- Variables, references, totals, dimensional units, dates/time zones, cached currency.
- Native system integrations.

Improve:

- Show the parsed interpretation and assumptions.
- Require clarification for materially different valid interpretations.
- Use exact/decimal arithmetic by default and identify approximations.
- Make rate source/time, zone, calendar semantics, rounding, and precision inspectable.
- Set and publish performance budgets.
- Make storage recoverable independently of the library index.

Defer or reject initially:

- Chat/LLM evaluation.
- Weather, stocks, crypto trading, Wolfram-style knowledge, tax tables, inflation databases, and regulatory claims.
- Trip planning, rich email, app generation, collaboration, mobile clients, and plugin execution.
- Plotting, symbolic calculus, matrices, and a visible CAS.

These may be reconsidered only when a validated user job cannot be served by the composable core.

---

## 3. Target users and jobs

### 3.1 Primary users

- **Everyday Mac user:** discounts, tips, time, conversions, budgets, comparisons.
- **Knowledge worker:** quick models with context, rates, dates, variables, and reusable sheets.
- **Developer/designer:** programmer literals, CSS/screen units, timestamps, durations, bandwidth, CLI/Shortcuts.
- **Engineer/scientist:** dimensionally correct compound units, scientific notation/functions, precision visibility.
- **Finance-aware user:** transparent decimal money math and explicit assumptions—not unqualified regulatory advice.

### 3.2 Core jobs to be done

1. “Give me the answer before a web page or spreadsheet opens.”
2. “Let me write the problem the way I naturally describe it.”
3. “Keep enough context that I can trust, revise, and reuse the work.”
4. “Convert mixed quantities without manually normalizing them.”
5. “Tell me when my words could mean different things.”
6. “Let me inspect exactly how the result was produced.”
7. “Stay out of my way and off the network.”

### 3.3 Launch success scenarios

All must be polished before adding specialist breadth:

```text
$1,480 - 20%
20% of $1,480
$50 is what % of $200

flight = 8h 35m
leave = Sep 18 4:30pm in Delhi
leave + flight in New York

room = 6m × 4.2m
paint coverage = 11 m²/L
2 coats for room / paint coverage

principal = $25,000
rate = 6.5% per year
monthly payment(principal, rate, 5 years)

3 GiB at 75 Mbps
0xff + 0b1010 in decimal
```

---

## 4. Experience specification

## 4.1 Quick Ganit

Purpose: disposable calculations with near-zero ceremony.

Behavior:

- User-configurable global shortcut, proposed default **⌥Space** only if conflict detection passes; otherwise choose during onboarding.
- A compact standard floating panel appears near the current screen's center, immediately focused.
- Multiline text is allowed; answers align on the right.
- Return inserts a new line. **⌘Return** copies the current/last result and dismisses. Escape dismisses without destroying the scratch buffer.
- A “Keep as Sheet” command promotes the buffer to the Workspace without retyping.
- Reopening restores the last quick buffer by default; “Always start empty” is an option.
- No Dock activation unless the user promotes the calculation or opens the Workspace.
- Status/provenance can be expanded, never shown as a permanent inspector.

Do not:

- Use a borderless custom window that breaks normal focus/accessibility.
- Poll the clipboard.
- save quick calculations to search history without an explicit preference.
- animate digits or use continuous visual effects.

## 4.2 Workspace window

Use a standard titled, resizable macOS window.

Three structural regions:

1. **Sidebar** — initially visible, hideable, system-resizable.
2. **Editor** — dominant center surface.
3. **Optional detail popover/inspector** — hidden by default; opens for the selected answer/error.

Sidebar model:

- Quick access: All Sheets, Favorites, Recent.
- User folders.
- Archive and Trash.
- Search field/command.
- Rows show title and restrained modified-time preview, not answer clutter.
- Standard context menu plus equivalent menu/keyboard commands.
- Narrow-window mode may hide the sidebar, but the editor remains fully usable.

Default toolbar:

- Sidebar toggle.
- New Sheet.
- Search.
- Optional Share after sharing exists.

Do not place Settings, formatting, angle mode, precision, or standard Edit actions in the default toolbar. Support native toolbar customization where appropriate.

## 4.3 Editor and answer column

The editor is an AppKit text system surface (`NSTextView`/TextKit), not a custom canvas.

Each visual line has:

- Source text.
- Optional semantic decoration that never changes source offsets.
- An aligned answer cell when evaluable.
- A subtle state marker for approximate, stale-live-data, warning, ambiguous, or error states.

Interaction:

- Results update as the user types, with evaluation scheduled after the text system commits the edit/IME composition.
- Answers remain selectable and copyable.
- Double-click answer inserts a stable upward reference; Option-double-click copies displayed answer.
- Hover may reveal detail, but every hover action has a menu/keyboard/accessibility equivalent.
- Selecting an answer and pressing Space opens the interpretation card.
- The current line's answer may be slightly emphasized; avoid persistent boxes around all results.
- Blank lines divide implicit total scopes.
- Headings/dividers create explicit semantic sections.

Interpretation card:

- Normalized expression.
- Typed operands and result.
- Applied unit conversions.
- Currency provider, observation date, fetch time, and stale status.
- Resolved time-zone identifier and DST offset.
- Calendar versus fixed-duration semantics.
- Precision/rounding and whether any operation is approximate.
- Referenced lines/variables, with jump actions.

Error presentation:

- Underline the exact source range.
- Show one concise plain-language message and one smallest correction/example.
- Preserve the last valid answer only if clearly marked stale; default to no answer for invalid current text.
- Never show `NaN`, `undefined`, a blank “success,” or a guessed zero.
- VoiceOver receives the same range/message without announcing on every keystroke.

Ambiguity presentation:

- Choose silently only when interpretations are mathematically equivalent or a documented locale preference makes the choice unambiguous.
- For materially different results, show compact choices such as **calendar month / 30-day duration**.
- Remember explicit choices at sheet scope when safe and make the remembered assumption visible.

## 4.4 Visual language

Desired character: calm, precise, warm, and unmistakably Mac.

- Use system typography, semantic colors, SF Symbols, standard controls and materials.
- Let source and answer typography create hierarchy; decoration is secondary.
- Editor uses an opaque/reliably legible content surface. Vibrancy belongs to structural chrome, not behind syntax-colored text.
- Default expression text: system body size or 14 pt. Answer numerals use tabular figures; do not default the whole editor to monospaced text.
- Use one restrained accent for interactive state. Warnings/errors must include noncolor cues.
- Dark Mode, Increase Contrast, Reduce Transparency, Reduce Motion, accent color, and desktop tinting are first-class test modes.
- On newer macOS versions, adopt Liquid Glass only through standard AppKit toolbar/sidebar APIs. Do not custom-paint glass.
- No gradients for decoration, oversized hero controls, skeuomorphic tape, keypad, bouncing answers, or gratuitous cards.

## 4.5 Menus and shortcuts

Use conventional menus and standard shortcuts. Proposed app-specific commands must be validated for conflicts and localized layouts.

- **Ganit:** About, Settings… (⌘,), Services, Hide, Quit.
- **File:** New Sheet (⌘N), New Window, Open…, Close (⌘W), Export…, Print (⌘P).
- **Edit:** native Undo/Redo, Cut/Copy/Paste, Select All, Find, spelling/substitutions as supported.
- **Calculate:** Copy Result (⇧⌘C), Copy Full Precision, Insert Reference (⌘\), Insert Subtotal (⌘T), Recalculate, Stop, show interpretation, angle/display options.
- **Format:** Heading, Comment, Divider, Highlight only after each exists.
- **View:** Sidebar, Toolbar, Customize Toolbar, Answer Details, zoom/text-size, Full Screen.
- **Window:** standard window commands and Quick Ganit.
- **Help:** searchable grammar, functions, examples, shortcuts, data provenance, privacy.

New sheet focus enters the editor. Return inserts a newline. Escape dismisses transient UI or cancels active work and never clears content.

## 4.6 Onboarding and discoverability

First launch is at most three lightweight steps:

1. Explain “type what you want to calculate” with executable examples.
2. Offer and conflict-check the global shortcut.
3. State the privacy promise and whether anonymous diagnostics are disabled (default: disabled).

A new empty sheet contains nonpersistent faint examples such as:

```text
20% off $85
12 km in miles
next Friday + 3 weeks
```

They disappear on input. Help contains a searchable, runnable example gallery generated from the same test corpus used by the engine.

No mandatory account, tutorial tour, sample library, or preference questionnaire.

---

## 5. Functional scope

Legend:

- **P0:** launch-quality core.
- **P1:** power and platform completeness.
- **P2:** only after real usage validates demand.
- **Not planned:** contradicts current product principles.

### 5.1 P0 calculation language

#### Arithmetic and numbers

- `+ - × * ÷ / ^`, unary signs, parentheses, implicit multiplication only where unambiguous.
- Integers of arbitrary size.
- Exact rational representation where possible.
- Arbitrary-scale decimal representation for typed decimals and money.
- Scientific notation.
- Constants π, e with explicit approximate semantics.
- `sqrt`, roots, `abs`, `min`, `max`, `round`, `floor`, `ceil`, powers.
- Trigonometric/log functions with explicit approximation and angle mode.
- Binary/octal/hex literals and conversions; bitwise operations only on integers.
- Never silently coerce an out-of-range integer to floating point.

#### Percentages and rates

- `20% of 50`.
- `$50 + 8%`, `$50 - 20%`, `20% off $50`, `8% on $50`.
- `$50 is what % of $200`.
- percentage change and reverse-percent forms.
- Rate quantities such as `$45/hour`, `6.5%/year`, `75 MB/s`.
- `%` is not modulo. Use the word `mod` for modulo to remove a common ambiguity.

#### Units and dimensions

- Length, area, volume, mass, time/duration, temperature, angle, speed, acceleration, force, pressure, energy, power, data, and data rate.
- SI and binary prefixes with correct case.
- Compound unit algebra: `m/s²`, `kg·m/s²`, `$ / month`.
- Dimensional validation on addition/subtraction and conversion.
- Ratio and affine conversions modeled separately; temperature arithmetic gets explicit rules.
- `in`, `to`, `as`, `into` conversion phrases while preserving `inches` as a unit token.
- Result-unit selection based on explicit request, operand context, and locale—not arbitrary prettification.

#### Variables, references, and sections

- Single- and multi-word variables: `monthly rent = $2,100`.
- Declaration before use; unknown identifiers are errors, not prose.
- Top-to-bottom scope, resettable by explicit divider/section.
- Stable upward line references; no backward references in v1, preventing cycles.
- Rename variable with Always/Ask/Never preference.
- `previous`/`prev`, `sum`/`total`, `average`/`avg`, `median`, `count`.
- Explicit subtotal line.
- Headings, comments, labels, blank lines, dividers.

#### Dates, durations, and time zones

- Absolute dates, local times, date-time values, calendar periods, and fixed durations are distinct types.
- `today`, `tomorrow`, weekdays, explicit dates, and ISO-8601.
- Add/subtract calendar periods and fixed durations with visible semantics.
- Difference between dates/times.
- Named IANA zones; display resolved identifier and DST offset.
- Reject or clarify nonexistent/duplicated local times.
- Avoid ambiguous abbreviations such as CST unless the sheet resolves them.
- `now`/`today` are injected evaluation context, making tests deterministic.

#### Currency

- ISO 4217 codes and common localized symbols.
- If `$`/`¥` is ambiguous, use sheet locale preference or ask.
- Money uses decimal arithmetic; no binary floating-point path.
- Offline cached rates with source, observation date, fetch time, and stale warning.
- Exact cross-rate calculation from one snapshot.
- Results labeled indicative and not for trading/payment settlement.
- Manual rates are supported and visibly override downloaded rates.

### 5.2 P0 sheets and library

- Create, rename, duplicate, move, pin/favorite, archive, trash, restore, permanently delete.
- Folders and smart lists (All, Recent, Favorites).
- Search source text and title locally.
- Autosave atomically after edits settle; save immediately on deactivation/termination.
- Daily rotating backups and “Restore Previous Version.”
- Open a sheet in another window.
- Import/export UTF-8 plain text without mangling source.
- Copy visible result; copy full precision; copy selected lines as text with optional answers.
- Native undo/redo for all persistent mutations.
- State restoration for window, sheet, cursor, selection, scroll, sidebar and split positions.

### 5.3 P0 efficiency and privacy

- No account, analytics, crash upload, remote config, ads, AI, or network for core operation.
- Currency update is the only planned automatic network feature; it is disableable and sends no expression text.
- App Sandbox, hardened runtime, minimal entitlements.
- No clipboard polling or raw-history Spotlight indexing.
- No idle polling timers; data refresh uses system scheduling and stops when unnecessary.

### 5.4 P1 power features

Implement only after P0 metrics and usability pass:

- Global definition sheet for reusable variables and custom units.
- Tags and tag aggregates if sections/totals prove insufficient.
- Transparent generic finance functions: compound interest, payment, present/future value, hourly rates. Label assumptions and estimates.
- Statistics over explicit lists/ranges.
- Custom display formats and significant figures.
- Selection-based total/average/count.
- Scrub a selected numeric literal with Option-drag plus keyboard alternative.
- macOS Service: Evaluate Expression.
- App Intent/Shortcuts: Calculate Expression and Open Sheet.
- URL callback scheme with bounded, explicit actions.
- Quick Look for exported Ganit documents.
- CLI reusing the exact engine and grammar; no separate partial implementation.
- Print/PDF/CSV and accessible HTML export.
- Optional Spotlight indexing of sheet titles/metadata only, off by default.
- Locale-aware parser packs after English grammar stability; UI strings are localized from the start.

### 5.5 P2 candidates with explicit entry criteria

- iCloud Drive sync only after a documented offline/concurrent-edit conflict model, restore drills, and a reliability beta.
- iPhone/iPad only after the engine and document format are stable and shared without conditional forks.
- Plugin/custom-function execution only with a capability model, signing/sandbox design, deterministic API and clear support burden.
- Symbolic algebra/plotting only if repeated research shows users leave Ganit for these jobs more often than they value simplicity.

### 5.6 Not planned in the calculation path

- LLM-generated arithmetic or hidden probabilistic parsing.
- Automatic clipboard monitoring.
- Unattributed web answers.
- Live trading prices or transaction-rate claims.
- Regulatory tax/APR/compliance claims without jurisdiction-specific specifications and golden vectors.
- A social/community feed, account system, or cloud lock-in.

---

## 6. Correctness contract

This section is normative. Implementation convenience must not weaken it.

### 6.1 Evaluation pipeline

```text
source snapshot
  → line segmentation with stable IDs
  → locale-aware lexer with exact source ranges
  → phrase normalization (lossless mapping to source)
  → deterministic parser
  → typed AST
  → name/reference resolution
  → dimensional/type validation
  → dependency graph update
  → evaluation with injected context
  → formatting
  → explanation/provenance
  → immutable result snapshot for UI
```

No UI code performs calculation. No formatter reparses source. No live-data provider returns a preformatted answer.

### 6.2 Value model

Use explicit tagged types rather than a universal `Double`:

- `IntegerValue` — arbitrary-sized signed integer.
- `RationalValue` — reduced integer numerator/denominator.
- `DecimalValue` — arbitrary-scale base-10 coefficient and scale, plus precision context where an operation requires rounding.
- `ApproximateValue` — explicitly approximate result with error/precision metadata where feasible.
- `QuantityValue` — numeric magnitude plus canonical dimensions and display unit.
- `MoneyValue` — decimal amount plus ISO currency.
- `DateValue`, `LocalTimeValue`, `InstantValue`, `CalendarPeriodValue`, `DurationValue`.
- `BooleanValue`, `TextValue`, `ListValue` only when required by functions.
- `ErrorValue` never participates as a numeric zero.

A vetted, pinned, permissively licensed BigInt implementation is acceptable after an ADR covering maintenance, binary size, benchmarks, and fuzz history. Building an unreviewed BigInt from scratch is not acceptable.

### 6.3 Exactness and approximation

- Integer, rational, finite decimal, unit-ratio, and money operations remain exact until an operation mathematically requires approximation or explicit rounding.
- Transcendental results carry an approximate marker.
- Display rounding never mutates stored value.
- “Copy result” copies displayed value; “Copy full precision” is distinct.
- Finance functions specify decimal precision and rounding rule per function.
- Division by zero, invalid domains, overflow in bounded APIs, and nonconvergence are explicit errors.

### 6.4 Units

- Dimensions are compile-time-like runtime types (exponent vector or equivalent), not strings.
- Addition/subtraction require compatible dimensions.
- Multiplication/division derive dimensions.
- Affine units cannot be treated as ratio units.
- Unit aliases are locale data; canonical units and conversion factors are versioned engine data.
- Foundation `Measurement` may cover presentation/common conversions, but Ganit's dimensional core cannot depend on Foundation accepting every compound expression.
- Seed factors from authoritative NIST/standards sources. Assess UCUM license obligations before redistributing its tables.

### 6.5 Dates and zones

- Use Foundation Calendar/TimeZone backed by IANA identifiers.
- Record calendar, locale, time zone, and “now” in the evaluation context.
- `1 month` as a calendar period is not `30 days`; the distinction is typed and displayed.
- For DST gaps/overlaps, ask or apply an explicit documented policy shown in details.
- Never calculate geographic zone behavior from fixed abbreviations/offsets alone.

### 6.6 Currency

- Currency metadata and rates are separate datasets.
- Store amount, source currency, target currency, rate, provider, observation timestamp/date, retrieval timestamp, and source snapshot ID.
- Use one immutable rate snapshot for an entire evaluation generation.
- Prefer official/provider-specific datasets such as ECB where scope permits. Frankfurter may be transport/bootstrap, not an undisclosed authority.
- Cache last-known-good snapshots atomically and retain enough previous snapshots to recover from corrupt or anomalous downloads.
- Weekend/holiday/stale behavior is visible.

### 6.7 Ambiguity rules

Maintain a versioned ambiguity registry with tests. Required cases include:

- `%` percent versus modulo.
- `in` conversion versus prose versus inch aliases.
- decimal/group separators.
- currency symbols with multiple currencies.
- `month/year/day` calendar period versus duration.
- 12/24-hour times and date component ordering.
- ambiguous or nonexistent local times.
- time-zone abbreviations and cities spanning multiple zones.
- identifier typo versus ignored prose.
- implicit multiplication versus adjacent quantities.

An ambiguity policy change is a language change and requires migration/release notes plus corpus updates.

### 6.8 Errors

Every error has:

- Stable machine code.
- Severity: incomplete while typing, warning, ambiguity, or error.
- Exact source range(s).
- Concise localized explanation.
- Optional fix-its.
- Underlying typed context for diagnostics, never raw user text in telemetry.

Incomplete input while typing (for example `2 +`) is not shown as a red error until it remains incomplete or focus leaves the line; it produces no fabricated answer.

---

## 7. Technical architecture

## 7.1 Stack decision

- **Language:** Swift 6 mode, strict concurrency enabled module by module.
- **UI:** AppKit-first (`NSApplication`, standard windows, `NSSplitViewController`, `NSToolbar`, `NSOutlineView`/lists, `NSTextView` and TextKit). SwiftUI may be used selectively for Settings or isolated views only after startup/memory/accessibility measurement.
- **Build:** Xcode project generated from a checked-in declarative project specification only if generation is deterministic; engine packages use Swift Package Manager.
- **Minimum OS:** macOS 14 initially. Newer toolbar/sidebar/material APIs use availability checks and system fallback behavior.
- **Dependencies:** minimal, pinned, and justified by ADR. No Electron, web view UI, embedded JS runtime, analytics SDK, database ORM, or networking framework dependency.

Why AppKit-first:

- The product is fundamentally a high-quality text editor and multiwindow Mac app.
- AppKit supplies mature text input, responder chain, menus, undo, Services, accessibility, toolbars, sidebars, restoration and fine-grained performance behavior.
- It also adopts current macOS structural design when standard components are used.

## 7.2 Module boundaries

```text
GanitApp
├── GanitWorkspaceUI        AppKit windows/sidebar/library coordination
├── GanitEditorUI           NSTextView layout, answer column, decorations
├── GanitQuickUI            global-hotkey panel
├── GanitDocuments          atomic storage, backups, migrations, search index
├── GanitData               versioned units/currency/time-zone aliases
├── GanitEngine             lexer/parser/AST/types/evaluator/dependencies
├── GanitFormatting         locale-aware result and explanation formatting
├── GanitSystemIntegration  Services, App Intents, URLs, Quick Look, CLI bridge
└── GanitDiagnostics        local signposts/metrics and user-exported diagnostics
```

Rules:

- `GanitEngine` is a pure Swift package with no AppKit, storage, global clock, locale singleton, or network calls.
- The engine receives immutable `EvaluationContext`, `DataSnapshot`, and source.
- UI consumes immutable result snapshots on the main actor.
- Providers fetch/validate data outside the engine, then publish versioned immutable snapshots.
- Documents store user intent/source and settings; derived answers are caches, never authoritative data.

## 7.3 Parser design

- Unicode-aware lexer retaining byte/grapheme/source ranges.
- Pratt parser for arithmetic precedence.
- Phrase recognizers feed deterministic typed grammar productions, not regex-only line extraction.
- Token normalization keeps a reversible source map.
- Parse prose as labels/comments only through explicit syntax and conservative documented rules.
- Unknown words in a would-be expression are surfaced; do not discard arbitrary words until a valid suffix remains.
- Grammar features are independently flaggable for corpus testing, not remotely configurable.

## 7.4 Incremental evaluation

- Assign stable line IDs independent of current line number.
- Store per-line source fingerprint, AST, definitions, references, dependencies, result, and diagnostics.
- On edit, re-lex/reparse changed logical lines and update affected names/edges.
- Re-evaluate only the transitive affected suffix/dependency set.
- Use generation IDs and cooperative cancellation; stale generations never commit to UI.
- Prioritize visible/current lines, but one generation uses one consistent context/rate snapshot.
- Time-dependent lines subscribe to the coarsest necessary boundary (day/minute), not a permanent per-second timer.

## 7.5 Storage model

Use a local library whose content remains recoverable without its index:

```text
~/Library/Application Support/<bundle-id>/
├── Sheets/<UUID>.txt          canonical UTF-8 source
├── Metadata/<UUID>.json       small versioned metadata, atomically replaceable
├── Index/index.sqlite         derived/rebuildable title/source search index
├── Backups/YYYY-MM-DD/...     bounded snapshots
└── Data/                      rates and version manifests
```

- Source and metadata writes use temporary file + fsync where appropriate + atomic replace.
- The SQLite index uses system SQLite directly through a tiny repository-owned adapter; no ORM. It is derived and rebuildable.
- A sheet is not lost when the index is corrupt.
- Metadata includes schema version, stable ID, title, folder ID, created/modified times, pin/archive/trash state, sheet calculation preferences, and source checksum.
- No answer cache is required for first implementation; add only after profiling proves benefit.
- Exported `.ganit` documents should be a documented, versioned, human-readable format. Prefer plain UTF-8 source plus conservative front matter or a package only if metadata requirements justify it; settle via an ADR and round-trip tests before public beta.
- Backups are bounded by age and size and are test-restored in CI.

## 7.6 Search

- Local only.
- Index title and source after debounced atomic save.
- Use SQLite FTS only if profiling shows basic file scan insufficient at the target library size.
- Search index is rebuildable and never the only copy of metadata/content.
- Spotlight metadata indexing is separate, opt-in, and title-only by default.

## 7.7 Networking

- `URLSession` only.
- Allowlist fixed HTTPS provider endpoints.
- No expression, sheet identifier, title, locale beyond protocol need, or device identifier is sent.
- Validate status, MIME type, payload size, schema, freshness, plausible ranges, duplicate/currency coverage, and optional signature/checksum.
- Exponential backoff via system scheduling; no tight retries.
- Last-known-good data always wins over malformed new data.
- Expose provider/license attribution in About/Data Sources and answer details.

## 7.8 Diagnostics

- `os_signpost` and MetricKit/local metrics for launch and evaluation development builds.
- No third-party telemetry SDK.
- Release builds keep privacy-safe aggregate performance counters locally only if needed, with Reset and Export Diagnostics commands.
- Export redacts expression text by default; user can explicitly include a selected reproduction.
- Crash reports remain in Apple's/system flow unless an explicit future opt-in design is approved.

---

## 8. Performance and footprint budgets

Measure on a documented baseline Mac (initially M1 MacBook Air, 8 GB) and the oldest supported OS. Also test a current Apple Silicon Mac. Record P50/P95 over repeated clean runs.

### 8.1 Release gates

| Metric | Target |
|---|---:|
| Global-hotkey panel, resident process → focused | P95 ≤ 100 ms |
| Cold launch → focused editable quick panel | P95 ≤ 450 ms |
| Cold launch → focused Workspace sheet | P95 ≤ 700 ms |
| Keystroke → visible answer, 1,000-line ordinary sheet | P95 ≤ 16 ms |
| Keystroke → visible answer, 10,000-line dependency stress sheet | P95 ≤ 50 ms |
| Simple single-expression engine evaluation | P95 ≤ 1 ms after initialization |
| Idle CPU after settling | effectively 0%; no periodic wakeups absent time/data needs |
| Quick panel idle resident memory | ≤ 55 MB target, ≤ 70 MB hard gate |
| Workspace idle resident memory, one medium sheet | ≤ 85 MB target, ≤ 110 MB hard gate |
| Compressed notarized download | ≤ 15 MB target, ≤ 20 MB hard gate |
| Installed app size | ≤ 35 MB target, ≤ 50 MB hard gate |
| App support overhead excluding user sheets/backups | ≤ 20 MB |
| Currency/data cache | ≤ 5 MB |
| Unbounded growth | zero known paths |

If platform/framework baseline makes a target unrealistic, record actual competitor/platform measurements and revise the budget through an ADR—never silently remove it.

### 8.2 Benchmark corpora

Check in deterministic fixtures:

- 200 representative launch expressions.
- 200 ambiguity/invalid-input expressions.
- 1,000-line mixed sheet.
- 10,000-line independent-lines sheet.
- 10,000-line chained dependency sheet.
- Unicode/RTL/IME stress source.
- Currency/date fixtures with frozen context/data snapshots.

### 8.3 Efficiency guardrails

- No polling loops.
- No per-line view objects for offscreen content if profiling shows scaling cost.
- No full-document parse on ordinary single-line edits after the incremental milestone.
- No syntax attributed-string rewrite of unchanged ranges.
- Cancel stale work and coalesce bursts without delaying simple feedback.
- Lazy-load library/search/help/data that is not needed for first focus.
- Keep large test/reference datasets out of the production bundle unless required at runtime.

---

## 9. Accessibility, internationalization, and native Mac quality

These are phase gates, not final polish.

### 9.1 Accessibility requirements

- Standard focus rings/highlights remain visible.
- Full Keyboard Access reaches every actionable element in sensible order.
- VoiceOver navigates sidebar containers efficiently, text by character/word/line, answers, diagnostics, references, and interpretation details.
- Add a rotor for lines with errors/warnings and optionally result lines if it improves navigation.
- Pointer-hover, drag, and gesture actions have menu/keyboard/accessibility actions.
- Do not chatter live answers to VoiceOver on every keystroke; announce explicitly requested evaluation, focus, or stable errors appropriately.
- Controls normally meet 28×28 pt and never fall below 20×20 pt.
- Text defaults near 13–14 pt and never below 10 pt.
- Editor/result text scales to at least 200% without clipping or loss.
- Custom contrast ≥ 4.5:1; target 7:1 for small text.
- Color is never the only meaning carrier.
- Reduce Motion removes nonessential transitions; Reduce Transparency provides opaque legible surfaces.

### 9.2 Internationalization requirements

- Localize all UI/accessibility/help strings from the first commit.
- Use leading/trailing layout and natural alignment.
- Do not blindly mirror mathematical expression order.
- Separate source parsing, canonical values, and localized display.
- Test Arabic/Hebrew mixed-direction source, CJK marked text, composed characters, localized digits, decimal/group separators, minus signs, currencies, long strings, and plural rules.
- P0 parser language can be English, but number/date/unit input must honor a documented locale policy and saved source must remain unambiguous.
- Additional natural-language grammars are data/code modules with their own compatibility corpus, not translated keyword lists pasted into one grammar.

### 9.3 macOS behavior requirements

- Standard close/minimize/zoom, resize, full screen, multiwindow, menus, responder chain, Services, sharing, print, Settings, Help and state restoration.
- Native text selection, Option/Command movement, dead keys, dictation, spelling choices where enabled, Find, paste, drag, and undo grouping.
- Main toolbar customizable; Settings toolbar stable/noncustomizable if used.
- Respect “Close windows when quitting an application.”
- Restore only appropriate state, not transient dialogs, stale errors, or in-progress network/evaluation tasks.

---

## 10. Security, privacy, and durability threat model

### 10.1 Assets

- Calculation text may contain financial, health, employment, travel, or business information.
- Sheets, backups, clipboard output, search indexes and crash diagnostics can all expose it.
- Exchange-rate provenance can materially affect decisions.

### 10.2 Required controls

- App Sandbox and least-privilege entitlements.
- No network entitlement if a build flavor excludes currency updates; otherwise narrowly scoped implementation.
- No clipboard reads except explicit Paste/Service/drag actions.
- No raw sheet content in logs, signposts, filenames, analytics, Spotlight or notifications.
- Security-scoped access only through standard panels for external files.
- Atomic persistence, checksums, schema validation, migration backups and restore verification.
- Bounded input and payload sizes for Services, URL schemes, import, CLI and network data.
- URL actions that mutate or reveal data require explicit foreground confirmation where appropriate.
- Plugin execution is absent until separately threat-modeled.

### 10.3 Sync entry criteria

Do not ship custom sync merely to claim parity. Before optional sync:

- Define stable document identity and operation/conflict semantics.
- Support offline concurrent edits and deterministic merge or explicit conflict copies.
- Never overwrite both divergent versions.
- Maintain local backups independent of sync.
- Test sign-out, quota exhaustion, permission loss, account switch, clock skew, interrupted upload/download, corruption and old-client formats.
- Provide a sync status console understandable without developer tools.
- Run a multi-device beta and restore drills.

Until then, reliable local storage plus explicit export/user-selected folder beats opaque unreliable sync.

---

## 11. Testing strategy

### 11.1 Engine tests

- Golden parse/typed-AST/evaluation/format tests.
- Property tests for arithmetic identities within type domains.
- Unit round-trip and dimensional algebra properties.
- Date tests around leap years, month ends, calendars, DST gaps/overlaps and zone changes.
- Currency tests with frozen snapshots, cross rates, rounding and stale behavior.
- Fuzz lexer/parser/import with random Unicode and malformed data.
- Differential tests against independent libraries/reference tools where semantics match.
- Metamorphic tests: formatting/whitespace aliases must not change meaning unexpectedly.
- Regression test for every engine bug before fix.

### 11.2 UI/editor tests

- NSTextView source offsets remain stable under syntax decoration and answer layout.
- Selection, copy, undo grouping, Find, IME composition, bidi text, drag/drop, large paste, line insertion/deletion and references.
- UI automation for Quick Ganit, sheet CRUD, search, promote quick buffer, restore backup, import/export and menus.
- Snapshot tests are limited to stable layout/accessibility structure; do not overfit system rendering.
- Accessibility Inspector and manual VoiceOver scripts.

### 11.3 Storage tests

- Kill process at every persistence stage; recover old or new complete file, never partial source.
- Corrupt/missing index rebuild.
- Corrupt metadata quarantine and source recovery.
- Migration fixtures for every public schema version.
- Backup rotation and actual restore verification.
- Disk-full, read-only, permission, rename and concurrent-window behavior.

### 11.4 Performance tests

- XCTest measure/signpost suites for engine, incremental edit, layout and launch.
- Release configuration on real hardware; debug numbers are informational only.
- Instruments: Time Profiler, Allocations/Leaks, Energy Log, Points of Interest, File Activity and Network.
- Track benchmark history and fail CI on statistically meaningful regressions beyond an agreed tolerance.

### 11.5 Manual release matrix

- Minimum and latest macOS.
- Apple Silicon; Intel only if chosen as supported after measurement.
- Light/Dark × Increase Contrast × Reduce Transparency.
- Reduce Motion.
- 100%, 150%, 200% editor text.
- VoiceOver and keyboard-only.
- English, pseudolocalized, Arabic/Hebrew, CJK input and at least one comma-decimal locale.
- Offline, stale rate, malformed rate and no-network cases.
- Fresh install, upgrade/migration and restore from backup.

---

## 12. Implementation roadmap

Each phase is a vertical quality gate. A later agent should execute phases in order, keep the app runnable, and not pull P1/P2 scope forward.

## Phase 0 — Repository and decision records

**Goal:** A reproducible, minimal native skeleton and explicit contracts.

**Status:** Complete — verified 2026-09-14.

Tasks:

- [x] Initialize Git and add a focused `.gitignore`.
- [x] Add `README.md`, contribution/testing instructions and license decision placeholder.
- [x] Record ADRs for AppKit-first UI, minimum macOS/Intel support, numeric representation/BigInt dependency, storage/export format, unit-data licensing and currency provider.
- [x] Create Swift packages/modules matching section 7.2.
- [x] Add deterministic formatting/linting only if tools are pinned and fast.
- [x] Configure CI for build and package tests on supported Xcode.
- [x] Add benchmark fixture targets without setting optimistic pass claims.
- [x] Add privacy manifest/entitlement baseline with no network initially.

Exit criteria:

- [x] Clean checkout builds and launches a standard empty window.
- [x] Engine test target runs without launching the app.
- [x] Production bundle has no third-party SDK or accidental entitlement.
- [x] ADRs settle all decisions that would otherwise fork Phase 1.

## Phase 1 — Typed arithmetic engine

**Goal:** Trustworthy deterministic evaluation independent of UI.

Tasks:

- [x] Implement source ranges, tokens, lexer and Pratt parser.
- [x] Implement Integer/Rational/Decimal/Approximate values and typed errors.
- [x] Implement arithmetic, precedence, parentheses, powers, core functions and programmer literals.
- [x] Inject locale, angle mode, precision, `now`, calendar and zone through `EvaluationContext`.
- [x] Implement result formatting separate from values.
- [x] Add golden/property/fuzz corpus and CLI-like internal test harness.
- [x] Benchmark simple expressions and record baseline.

Exit criteria:

- [x] No ordinary integer/decimal/money-intended operation uses `Double` implicitly.
- [x] Every source-expression failure includes code/range/message.
- [x] Exact versus approximate output is inspectable.
- [x] Core corpus and fuzz smoke tests pass under sanitizers where supported.

## Phase 2 — Units and percentages

**Goal:** Make the highest-frequency natural calculations dimensionally correct.

Tasks:

- [x] Add percentage phrase grammar and semantics.
- [x] Add dimensions, compound units, prefixes, ratio and affine conversions.
- [x] Seed a reviewed minimal unit catalog with source/license metadata.
- [x] Add dimensionally typed rate quantities.
- [x] Add explicit conversion syntax and result-unit selection.
- [x] Add ambiguity cases (`in`, `%`, symbols, implicit multiplication).
- [x] Add round-trip/dimensional property tests including compound engineering units.

Exit criteria:

- Incompatible dimensions fail visibly.
- Compound units survive multiplication/division/conversion.
- Temperature edge semantics are documented and tested.
- `%` never silently means modulo.

## Phase 3 — Multiline model, variables and incremental dependencies

**Goal:** Turn expressions into a reactive thinking document.

Tasks:

- [x] Implement stable line IDs and line segmentation.
- [x] Add explicit comments, labels, headings, blank sections and dividers.
- [x] Add variables, multi-word names, declarations and conservative unknown-identifier errors.
- [x] Add upward references, previous, totals/average/median/count and subtotals.
- [x] Build dependency tracking, invalidation, generation IDs and cancellation.
- [x] Add 1k/10k sheet fixtures and affected-only evaluation assertions.

Exit criteria:

- Editing an upstream value deterministically updates dependents.
- Cycles are impossible under the upward-reference rule.
- A one-line edit does not reparse/re-evaluate unrelated lines after incremental mode activates.
- Performance meets engine-side portions of section 8.

## Phase 4 — Native editor vertical slice

**Goal:** A beautiful, fully native single-sheet experience before library breadth.

Tasks:

- [x] Embed `NSTextView` with correct IME, bidi, selection, responder-chain and undo behavior.
- [x] Render aligned answers without inserting answer text into source storage.
- [x] Add syntax/state decoration using exact source ranges.
- [x] Add result selection/copy and interpretation/error UI.
- [x] Add standard menus and commands; Return/newline and ⌘Return behavior.
- [x] Add text scaling, appearance, contrast and accessibility semantics.
- [x] Instrument edit-to-answer and layout latency.

Exit criteria:

- Native editor behavior and VoiceOver source navigation survive decoration.
- Copying source returns source only; copying result has displayed/full-precision variants.
- Errors and ambiguities are useful by keyboard and VoiceOver.
- 1,000-line keystroke target passes on baseline hardware.

## Phase 5 — Durable sheets and library

**Goal:** Never lose work; organize it without turning Ganit into a note manager.

Tasks:

- [x] Implement source/metadata files, atomic replace and checksums.
- [x] Implement derived index and rebuild flow.
- [x] Add autosave, backups, restore and migration framework (migrations wait for a second schema; see docs/storage/autosave-and-backups.md).
- [x] Build sidebar/folders, sheet CRUD, favorite, archive, trash and search.
- [x] Add multiwindow and per-document undo/state restoration.
- [x] Add plain-text import/export and define public `.ganit` format.
- [x] Test injected process kills, corruption, disk-full and restore.

Exit criteria:

- No tested interruption produces a partial canonical sheet.
- Deleting the index does not lose content and rebuild works.
- A backup is restored in an automated test, not merely created.
- Window/sheet/cursor/sidebar state restores appropriately.

## Phase 6 — Quick Ganit

**Goal:** Best-in-class invocation speed.

Tasks:

- [x] Implement standard accessible floating panel and global shortcut registration/conflict UX.
- [x] Immediate focus, multi-line answers, copy-and-dismiss and promote-to-sheet.
- [x] Add Dock activation behavior and all-screen/Space handling.
- [x] Add safe optional quick-buffer persistence.
- [x] Measure resident and cold invocation paths.

Exit criteria:

- Keyboard-only workflow from shortcut to clipboard is reliable.
- Escape never destroys source unexpectedly.
- Quick/Workspace use exactly the same engine and formatting.
- Section 8 quick-panel launch/memory hard gates pass.

## Phase 7 — Dates, durations and time zones

**Goal:** Make traditionally error-prone calendar math trustworthy.

Tasks:

- [x] Implement distinct date/time/instant/calendar-period/duration values.
- [x] Add common English date phrases and ISO input.
- [x] Add named IANA zone parsing with conservative alias data.
- [x] Implement DST gap/overlap clarification and interpretation detail.
- [x] Add frozen-context tests across leap/month-end/DST/zone-history cases.
- [x] Schedule time-dependent recalculation only at required boundaries.

Exit criteria:

- Calendar month versus duration is never hidden.
- Resolved zone and offset are inspectable.
- No permanent per-second timer for sheets that do not need one.
- Date corpus passes deterministically with frozen context.

## Phase 8 — Currency and data provenance

**Goal:** Useful online-aware calculations without sacrificing privacy or trust.

Tasks:

- [x] Finalize provider/legal ADR and attribution.
- [x] Implement strict downloader/validator and immutable versioned snapshots.
- [x] Implement money grammar, ISO metadata, symbols and manual rates.
- [x] Add stale/weekend/offline status and answer provenance.
- [x] Add refresh scheduling/backoff and last-known-good rollback.
- [x] Verify network traffic contains no calculation text or identifiers.

Exit criteria:

- Full currency workflow works offline after one snapshot.
- Corrupt/anomalous payload cannot replace last-known-good data.
- Amount math is decimal/exact and rate source/date is visible.
- Network/privacy and cache-size gates pass.

## Phase 9 — Accessibility, localization and visual refinement gate

**Goal:** Reach Mac-assed quality before feature expansion.

Tasks:

- [x] Run the complete section 9 and manual matrix. Automated audit and matrix in docs/quality/section-9-matrix.md; rows marked "Needs a person" are not run.
- [x] Refine VoiceOver containers, actions, focus and error/result navigation.
- [ ] Add pseudolocalization and fix truncation/bidi/IME issues.
- [ ] Finalize semantic color/type/spacing/icon system and system-material behavior.
- [ ] Test minimum size, multiple displays, full screen, Spaces and restoration.
- [ ] Conduct task-based usability testing with novices and Numi/Soulver power users.

Exit criteria:

- No mouse-only essential action.
- VoiceOver can complete launch success scenarios.
- 200% text and accessibility appearance modes remain usable.
- At least five novice and five power-user sessions reveal no repeated P0 comprehension blocker.

## Phase 10 — System integration and P1 power

**Goal:** Extend reach while preserving one engine and one mental model.

Tasks in priority order:

- [ ] Service and App Intent for pure expression calculation.
- [ ] Global definitions/custom units.
- [ ] Selection aggregates and optional tags.
- [ ] Generic transparent finance functions.
- [ ] URL callbacks with input/security limits.
- [ ] Quick Look, print/PDF/CSV/HTML exports.
- [ ] CLI linked to the same engine.
- [ ] Optional title-only Spotlight index.

Exit criteria:

- No integration implements its own parser/evaluator.
- Headless actions are deterministic, bounded and privacy-preserving.
- New features do not regress launch/idle/bundle hard gates.

## Phase 11 — Beta, adversarial correctness and durability

**Goal:** Prove trust before public release.

Tasks:

- [ ] Expand compatibility corpus by testing Numi, Soulver, Apple Math Notes and Ganit on matching semantics.
- [ ] Recruit mixed-domain beta users; collect reports without automatic sheet upload.
- [ ] Run parser fuzzing continuously and triage every crash/hang.
- [ ] Conduct backup restore day and migration rehearsal.
- [ ] Audit sandbox, entitlements, URL/Service/import limits and data provenance.
- [ ] Run performance suite on clean machines and compare with competitors.
- [ ] Freeze grammar/data/document schemas; publish known limitations.

Exit criteria:

- Zero known data-loss, crash, silent-wrong-answer or P0 accessibility bugs.
- All hard performance/footprint budgets pass or have evidence-backed approved ADR revisions.
- Every known ambiguity either resolves deterministically by documented context or asks.
- Upgrade/rollback/export recovery instructions are tested.

## Phase 12 — Release and post-release discipline

**Goal:** Sustainable quality, not a launch-only showcase.

- [ ] Notarized direct build first; evaluate Mac App Store separately against sandbox/update/business needs.
- [ ] Transparent one-time purchase/trial model decision; no core subscription requirement.
- [ ] Publish privacy statement, data-source attribution, grammar reference, compatibility corpus highlights and performance methodology.
- [ ] Provide in-app update path appropriate to distribution.
- [ ] Maintain a release train with regression tests for every fixed parser issue.
- [ ] Track anonymized-by-design product learning through voluntary feedback, support themes and opt-in studies—not automatic expression analytics.

---

## 13. Feature entry checklist

Before adding any capability after P0, answer yes to all:

1. Does it solve a repeated calculation job for the target users?
2. Can it compose with normal lines rather than creating a separate mode?
3. Can its semantics be deterministic, testable and explainable?
4. Can it run locally, or clearly expose unavoidable live data?
5. Is its correctness source authoritative and license compatible?
6. Does it preserve launch, typing, idle, memory and bundle budgets?
7. Can it be fully keyboard and VoiceOver accessible?
8. Can source/documents remain readable without the feature?
9. Is the support/maintenance burden acceptable?
10. Is it more valuable than improving existing clarity/reliability?

A “no” means defer, redesign, or reject.

---

## 14. Definition of done for every implementation phase

A later agent must not mark a phase complete until:

- Scope matches this plan and no later-phase feature was pulled in casually.
- User-visible semantics are documented in Help/reference.
- Unit, regression and relevant property/fuzz tests exist.
- Accessibility labels/actions and keyboard commands exist with pointer UI.
- Error, offline, cancellation, persistence and migration paths are handled.
- Focused performance is measured in release configuration.
- No expression/source text is added to logs or network payloads.
- Changed formats/grammar/data have versions and migration notes.
- Final diff contains no generated/scratch reports or unreviewed dependency.
- A fresh-context review checks correctness, simplicity, accessibility and resource regressions.

Recommended per-phase agent loop:

1. Read this plan and relevant ADRs.
2. Restate the phase's exit criteria and identify unresolved decisions.
3. Write failing focused tests/benchmarks first where possible.
4. Implement the smallest vertical slice with one writer.
5. Run focused tests, then full engine/app tests.
6. Profile the changed path if it is in startup/editor/evaluation/storage.
7. Run fresh-context review.
8. Apply only validated findings and rerun affected gates.
9. Update the phase checklist, ADRs, known limitations and benchmark record.
10. Stop at the phase boundary for explicit acceptance.

---

## 15. Product validation plan

### 15.1 Research prototypes

Before visual production work, build disposable spikes for:

- TextKit answer-column alignment on wrapped/RTL/very long lines.
- Syntax decoration without breaking IME/selection/VoiceOver/source offsets.
- Incremental dependency behavior at 10,000 lines.
- Global-hotkey focus timing from resident and terminated states.
- Compound/affine unit value model.

Spikes do not enter production unchanged. Capture conclusions in ADRs and delete prototype debris.

### 15.2 Usability tasks

Measure completion, time, corrections and confidence—not just preference:

1. Calculate a discount and copy the answer.
2. Convert mixed currencies while offline with cached data.
3. Build a three-variable monthly-cost sheet and revise one input.
4. Convert a compound engineering unit.
5. Add one calendar month across month-end and explain the result.
6. Resolve an ambiguous currency/date/time-zone input.
7. Find and reopen a saved calculation.
8. Recover an accidentally deleted or overwritten sheet.

### 15.3 Success measures

- ≥ 90% first-try completion for basic quick calculations without onboarding help.
- Median shortcut-to-copied-answer faster than Numi/Soulver on the same tasks/hardware.
- No repeated confusion about whether a displayed value is current, approximate, stale, or assumed.
- Power users can discover variables/references/totals from menus/Help without a tutorial.
- Users can explain a currency/date/compound-unit answer after opening details.
- Zero data loss across beta restore/conflict/interruption tests.

---

## 16. Open decisions to settle in Phase 0

Do not let these remain implicit:

1. **Distribution:** direct notarized app, Mac App Store, or both.
2. **Minimum CPU:** whether Intel is supported; base on real performance/support cost, not sentiment.
3. **BigInt:** vetted dependency/vendor choice and update policy.
4. **Public document format:** front-matter text versus package; must preserve plain-text recovery.
5. **Currency provider:** official coverage, attribution, licensing, availability and cache policy.
6. **Unit dataset:** Foundation + reviewed extensions versus licensed UCUM-derived data.
7. **Global shortcut:** default after conflict/accessibility testing.
8. **Pricing/trial:** product decision; architecture must not require an account.
9. **Locale policy:** exact P0 parser locales and unambiguous source serialization.

Default if an owner decision is unavailable: choose the simpler local/native option that preserves future migration, document it in an ADR, and do not introduce cloud/account/plugin infrastructure.

---

## 17. Research sources

Primary/current sources should be rechecked before implementation where versions, pricing, licensing or provider policy matter.

### Competitors

- [Numi official site](https://numi.app/)
- [Numi documentation/wiki](https://github.com/nikolaeu/numi/wiki)
- [Numi repository and CLI](https://github.com/nikolaeu/numi)
- [Numi privacy policy](https://numi.app/privacy.txt)
- [Numi Setapp reviews](https://setapp.com/apps/numi/customer-reviews)
- [Soulver official site](https://soulver.app/)
- [Soulver documentation](https://documentation.soulver.app/)
- [Soulver 4 changes](https://documentation.soulver.app/whats-new-in-soulver-4)
- [Soulver changelog](https://documentation.soulver.app/changelog)
- [Soulver App Store listing](https://apps.apple.com/us/app/soulver-4/id1508732804)
- [Soulver 4 review — Six Colors](https://sixcolors.com/post/2026/08/soulver-4-casts-a-wider-calculating-net/)
- [Soulver 3 review — MacStories](https://www.macstories.net/reviews/soulver-3-for-mac-the-macstories-review/)
- [Parsify releases](https://github.com/parsify-dev/desktop/releases)
- [Qalculate](https://qalculate.github.io/)
- [SpeedCrunch](https://www.speedcrunch.org/)
- [Calca](http://calca.io/)
- [Apple Calculator history guide](https://support.apple.com/guide/calculator/see-previous-calculations-calceebf81c8/mac)

### macOS design and platform

- [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)
- [Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo)
- [Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- [Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Make your Mac app more accessible to everyone — WWDC25](https://developer.apple.com/videos/play/wwdc2025/229/)
- [Build an AppKit app with the new design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/310/)
- [AppKit state restoration](https://developer.apple.com/documentation/appkit/restoring-your-app-s-state-with-appkit)
- [App Intents](https://developer.apple.com/documentation/appintents/appintent)
- [Core Spotlight](https://developer.apple.com/documentation/corespotlight)

### Correctness and data

- [NIST metric publications](https://www.nist.gov/pml/owm/owm-products-and-services/publications-and-documentary-standards/metric-publications)
- [UCUM specification](https://ucum.org/ucum)
- [UCUM license](https://ucum.org/license)
- [SIX ISO 4217 maintenance](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html)
- [ISO 4217 code policy](https://www.iso.org/iso-4217-currency-codes.html)
- [ECB reference rates](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html)
- [ECB statistics reuse policy](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html)
- [Frankfurter](https://frankfurter.dev/)
- [IANA time-zone database](https://www.iana.org/time-zones)
- [Unicode CLDR](https://cldr.unicode.org/)
- [IEEE 754-2019](https://standards.ieee.org/standard/754-2019.html)
- [CFPB Regulation Z Appendix J](https://www.consumerfinance.gov/rules-policy/regulations/1026/J)

---

## 18. Final direction

Ganit should feel almost empty until the user needs depth. The first five seconds are a cursor, a thought, and an answer. The next five minutes reveal references, variables, units and dates that behave consistently. The next five years should reveal that the files are durable, the arithmetic is explainable, and the app stayed fast because every feature had to earn its place.

Implement the engine and editor as the product. Treat sheets, quick invocation and Mac integrations as multipliers. Treat correctness, accessibility, privacy, recovery and performance as features visible in every interaction—not as cleanup phases after the app “works.”
