# Ganit macOS workflow audit — 18 September 2026

Ganit's basic calculator works well in the sampled workflows. The most valuable fixes concern keeping formulas correct through Undo, preserving the distinction between calculated and assisted answers, and preventing summaries from presenting incomplete totals as complete.

## Method and scope

Used the actual macOS UI through Computer Use, including keyboard entry, multiline paste, menus, selections, Help, interpretation popovers, Markdown Mode, Quick Ganit, CSV export, tab closing, and an app restart. About confirmed **Ganit 0.3.0 (0.3.0)** after relaunch from `/Applications/Ganit.app`; the Mac runs **macOS 26.6, build 25G72**. Source inspection at checkout `247ac00` helped identify likely implementation areas; that checkout is not proof of the installed binary's exact source revision.

The assistant was already configured and enabled. Only synthetic audit expressions were entered. Its provider, model, and credentials were not changed. Test sheets have `QA —` headings and remain in the library for reproduction. No app source changes were made.

Coverage included student mathematics, electronics, physics and scientific units, programmer numbers and data sizes, household budgets and recipes, financial arithmetic, travel dates and time zones, prose and Markdown, and macOS keyboard workflows. This is an exploratory audit, not a complete grammar certification, performance benchmark, or VoiceOver listening test.

## Ordered fix list

Severity describes consequence; priority describes scheduling. **P1** means fix before broad rollout, **P2** the next product iteration, and **P3** polish. Complexity is a relative estimate: **S** a localized change, **M** a change across several components, **L** substantial design or architecture work. ROI is qualitative user benefit relative to likely effort, not a measured financial return. Ordering considers correctness, lost work, reach, effort, and dependencies.

| Order | ID | Issue and observed consequence | Severity | Priority | Complexity | ROI | Classification |
|---:|---|---|---|---|---|---|---|
| 1 | G01 | Undo reverses automatic reference renumbering separately from the newline that caused it; a valid formula silently reads different values. | High | P1 | M | Very high | Reproduced defect |
| 2 | G02 | CSV strips AI provenance: purple model answers are exported as ordinary answers with no source or verification field. | High | P1 | S | Very high | Reproduced defect |
| 3 | G03 | Selection summary silently excludes failed or pending calculations and still presents a Total and Average. | High | P1 | S | Very high | Reproduced UX/correctness risk |
| 4 | G04 | A manual Change Answer correction disappears after app restart; the editing UI does not disclose its temporary lifetime. | High | P1 | M | High | Reproduced loss of user-entered answer; documented lifetime |
| 5 | G05 | A mortgage's exact fraction makes its interpretation popover enormous and much of the card unreadable in the captured view. | High | P1 | S | Very high | Reproduced layout defect |
| 6 | G06 | Calculate → Stop leaves an assistant request showing Asking…; there is no visible per-request Cancel. | Medium | P2 | M | High | Reproduced control mismatch |
| 7 | G07 | A line-level AI answer looks usable but cannot feed `line N` or `previous`; dependent formulas continue to report errors. | Medium | P2 | M | High | Deliberate distinction, insufficient UI explanation |
| 8 | G08 | Compact-window answer truncation removes units, time zones, and most of diagnostic messages. | Medium | P2 | S | High | Reproduced usability problem |
| 9 | G09 | Rounded exact numbers have no approximation marker; CSV also has no exact-value column. | Medium | P2 | S | High | Documented display policy with trust/export risk |
| 10 | G10 | The main sheet identifies AI answers by purple text without a visible textual AI badge. | Medium | P2 | S | High | Reproduced provenance/discoverability problem |
| 11 | G11 | No number-locale preference: decimal-comma input falls outside default syntax and may invoke AI for basic arithmetic. | Medium | P2 | M | High | Documented feature gap, reproduced |
| 12 | G12 | References and errors use physical line numbers, but the editor offers no numbered gutter. | Medium | P2 | S | High | Reproduced navigation gap |
| 13 | G13 | Number format is sheet-wide, preventing comfortable mixed decimal, hexadecimal, fraction, and scientific working. | Medium | P2 | M | Medium | Documented feature gap |
| 14 | G14 | Quick Ganit does not expose its copy-and-dismiss keyboard action in the panel. | Low | P3 | S | High | Reproduced discoverability gap |
| 15 | G15 | `2 + 3 =` produces a variable-name diagnostic rather than useful guidance about a trailing equals sign. | Low | P3 | S | Medium | Reproduced diagnostic mismatch |

## Reproduction details and proposed behavior

### G01 — reference updates and Undo must be one edit

Start a sheet with:

```text
# QA — final reference reproduction
10
20
line 2 + line 3
previous * 2
```

Place the caret before `10`, type `5`, then press Return. The resulting sheet contains `5`, `10`, `20`, and `line 2 + line 4`, yielding 25. Press Command-Z **once**. The newline remains, but the formula becomes `line 2 + line 3`, yielding **15**, and its dependent line yields **30**. Further Undo is needed to restore the preceding user edit. Reproduced both before and after relaunch.

The typed insertion itself also illustrates a reference hazard: typing a new value then Return before an existing value differs from pasting the same `5\n` atomically. Atomic paste correctly produced `line 3 + line 4`, preserving 30. The typed route first edits `10` into `510`, then splits it, so split semantics explain part of the difference. Do not treat the split alone as proof of a separate identity bug; provide an explicit Insert Line Above action or clearer line-reference tooling.

**Fix:** Group the initiating text change and every automatic reference rewrite into the same Undo transaction, restoring selection consistently. Verify Undo and Redo with typing, Return, paste, and multiple references. Likely area: `SheetEditorViewController.noteLineShift`, `renumberLineReferences`, and text-system undo grouping.

[Evidence: partial Undo after relaunch](screenshots/14-confirmed-partial-undo-after-relaunch.png), [typed insertion result](screenshots/06-reference-retargeting.png).

### G02 — exported assisted values lose their origin

In the locale sheet, `1,5 + 2,5` displayed **4 in purple** and `1.234,56 + 1` received an assisted answer. UI export to CSV produced:

```csv
Line,Source,Answer
2,"1,5 + 2,5",4
3,"1.234,56 + 1",1235.56
```

Nothing in these rows tells a recipient that a model supplied those values. This is especially troublesome when a colleague imports the CSV into a spreadsheet or copies answers into a budget or lab report.

**Fix:** Carry answer origin through `ExportedLine` and export a Source/Status field or clear AI annotation. Apply the same provenance model to HTML, PDF, print, and Copy with Results. Those additional formats were identified as sharing the limited export model through source inspection; their output was not separately validated in this session.

[Actual assisted CSV](locale-ai.csv), [main-sheet assisted results](screenshots/05-locale-ai-results.png). Likely areas: `ExportedLine`, `SheetDocumentRenderer`, `exportedLines()`.

### G03 — a partial selection total needs a warning

Select the four lines `10`, `20`, `1/0`, `30`. The summary shows **Count 3, Total 60, Average 20**, while `subtotal` appropriately refuses to use the failed line. The selected `1/0` was pending an assistant response in the captured state. The implementation collects only successful engine values, excluding both failures and pending lines.

The numbers are accurate for the successful subset; the issue is presenting them without saying they summarize only part of the selection.

**Fix:** Show selected calculation count, successful count, and failed/pending count. Suppress totals or label them explicitly as partial until all selected calculations have values. Likely area: `summarizeSelection()` and `SelectionSummaryBar`.

[Evidence](screenshots/08-selection-hides-errors.png).

### G04 — manual corrections are temporary without an in-flow warning

Wait for `10 kg of water in ml` to show `10000 ml`. Use Change Answer to enter **12345 ml** as an unmistakable synthetic override. Closing its tab and selecting the sheet again retained the override. Quit Ganit with Command-Q, relaunch, and reopen the sheet: the override is gone and the original diagnostic appears while the assistant can be asked again.

The developer documentation explicitly says answers are not saved with the sheet. The Change Answer dialog, however, offers no indication that the entered correction will be discarded on restart. Persisting source while discarding a manual answer undermines the user's expectation that their correction was saved.

**Fix:** Persist manual overrides keyed to prompt/text with origin and invalidation rules. If temporary answers are intentional, disclose that lifetime in the dialog and offer a way to save the corrected value into the sheet. Do not silently make old model answers look freshly verified.

[Before restart](screenshots/10-manual-assistant-override.png), [override survives tab close](screenshots/11-override-survives-tab-close.png), [after restart](screenshots/13-manual-override-lost-after-restart.png).

### G05 — bound interpretation-card size

Show Interpretation for `pmt(300,000 USD, 6% / 12, 360)`. Its enormous exact rational value is placed in a single unconstrained label, making the popover expand far beyond the normal card width. The screenshot captures the fraction stretching across the window, with the rest of the card largely outside the captured area. This is more serious than ordinary answer-column truncation because the escape route for recovering the full result is itself difficult to use.

**Fix:** Cap card width and height to the display's usable area. Wrap explanatory text; put very long exact values in a scrolling field with Copy Full Precision. Keep expression, readable result, and finance assumptions visible. Source inspection corroborates the unbounded intrinsic label layout in `InterpretationViewController`.

[Evidence](screenshots/03-unbounded-finance-popover.png). Screenshots are app-window captures, so they do not establish the exact amount of clipping at the physical display boundary.

### G06 — Stop does not stop the assistant workflow

Enter `5 kg of water in ml`, leave the line, and wait for Asking…. Choose Calculate → Stop. Asking… remains. Source inspection shows Stop cancelling the evaluation scheduler, while assistant requests are launched as separate tasks without handles retained by this controller.

**Fix:** Give each request a cancellation handle and visible Cancel action. Define whether Stop cancels both evaluation and assistance, or label the commands separately. Cancellation cannot retract data already sent or guarantee that a provider stops processing it; the UI should accurately describe what was cancelled.

[Evidence](screenshots/15-stop-leaves-assistant-running.png).

### G07 — line-level assistance and computable assistance look too similar

Use:

```text
# QA — assistant dependencies
10 kg of water in ml
line 2 * 2
previous + 1
```

After the assistant supplies `10000 ml`, the following lines still report that the preceding line has an error. The purple value replaces the displayed diagnostic, but the engine still cannot read the original expression. Explicit `ask_assistant(...)` values have different semantics and can participate in later arithmetic, as documented.

**Fix:** Explain “AI display answer; cannot be referenced” in the main UI and interpretation card, and offer an explicit Accept as Value/Insert Value action after parsing and user review. Unifying the two assistance paths should preserve provenance through every dependent formula.

[Evidence](screenshots/09-assisted-answer-unusable-reference.png).

### G08 — preserve meaning when answers do not fit

In the observed 640-pixel-wide window, `current = 5 V / resistance` and `current in mA` show truncated numeric strings, losing their unit suffixes. Time-zone answers lose their zone; diagnostic messages become “This part of the expres…” or “Line 2 has an error, so…”. The gutter offers no independent resize control.

**Fix:** Prefer a shorter significant-digit display that keeps the unit/zone, provide full text on focus/hover, and make answer width adjustable or allow wrapping. Short diagnostic titles can open full details. Keep truncation distinct from precision rounding.

[Examples](screenshots/01-truncated-results-and-interpretation.png), [calendar diagnostics](screenshots/02-dst-diagnostic.png).

### G09 — identify rounding and preserve precision on export

Set Format → Number Format → 2 Decimals. `1/3` displays **0.33** with no approximation marker, and CSV exports **0.33** with no exact-value field. Default formatting also displays a finite decimal expansion of `1/3` without a rounding marker. The engine remains exact; `1/3 * 3` correctly gives 1. This is a communication and transfer issue, not a finding of incorrect internal arithmetic.

**Fix:** Distinguish an exact displayed value from a rounded display, make the current format discoverable, and offer exact/full-precision export alongside human-readable Answer. Money already has a rounding marker, which provides a useful consistency model.

[Evidence](screenshots/04-unmarked-rounding.png), [actual rounded CSV](programmer-formats.csv).

### G10 — AI origin should not require recognizing a color

AI answers appear purple in the main sheet without an AI label beside them. Underlines indicate the original expression remains unresolved, but do not explain the source of the replacement answer. This is fragile for unfamiliar users, color discrimination, screenshots, and copying.

**Fix:** Add a compact AI badge with a textual accessibility label and an explanation on focus. Carry the same origin into copying and exports (G02). The accessibility listening behavior is unverified; do not infer a VoiceOver failure solely from Computer Use's tree.

[Evidence](screenshots/05-locale-ai-results.png).

### G11 — locale should be an explicit sheet preference

`1,234.56 + 1` calculates natively. `1,5 + 2,5` and `1.234,56 + 1` require assistance in the default sheet configuration. Settings offers no number-locale choice. Indian comma grouping did work: `1,00,000 * 2` gave 200,000 and rupee inputs were accepted.

**Fix:** Expose a number-locale preference with examples, seeded from an appropriate user setting but stored per sheet. Detect mismatched separators and offer a deterministic correction before suggesting assistance. This is a documented gap, not evidence of silent native miscalculation.

[Evidence](screenshots/05-locale-ai-results.png).

### G12 — references need a line-navigation affordance

The sheet displays `line 2`, `line 3`, and numbered reference errors, but no physical line numbers. View offers text-size, sidebar, separator, and fullscreen actions, but no line-number option. Headings, blank lines, and wrapped source make manual counting harder.

**Fix:** Offer a line-number gutter and Go to Line; clicking a reference should reveal/highlight its target. Keep physical lines distinct from visual wraps.

[Evidence](screenshots/14-confirmed-partial-undo-after-relaunch.png).

### G13 — permit per-answer formatting

The programmer sheet contains decimal 255, hexadecimal `0xff`, `1/3`, a quantity, money, and a date. Number Format changes the entire sheet. There is no per-line override, so a student or developer must choose one display policy for unrelated calculations. The known-limitations document confirms this design.

**Fix:** Add an answer-context-menu format override with a clear reset to the sheet default. Keep a sheet-wide default for convenience.

### G14 — expose Quick Ganit's primary shortcut

The panel visibly offers Keep as Sheet. Return inserts a newline. Command-Return copies a result and dismisses the panel, but that action has no visible button or shortcut hint in the panel.

**Fix:** Add “⌘↩ Copy Result and Close” as a compact hint or action, with a clear distinction from Keep as Sheet and a useful explanation when no result is available.

### G15 — diagnose a trailing equals sign at the user's level

`2 + 3 =` is interpreted as a malformed declaration and produces “A name is words…” with a declaration example. `2 + 3 =>` evaluates correctly. A calculator user reaching for equals receives guidance unrelated to their intent.

**Fix:** Detect a trailing equals sign after an expression and say “Remove =; answers appear automatically” or offer replacement with `=>` where appropriate. Keep malformed variable declarations diagnosed separately.

## Positive results and remaining validation

Sampled arithmetic and functions worked: percentages, precedence, right-associative powers, perfect and approximate roots, hexadecimal input, exact large integers, and `1/3 * 3`. Sampled conversions worked for temperature, distance, volume, mixed feet/inches, electrical quantities, energy, SI prefixes, and decimal/binary data sizes. Finance examples produced expected values, including zero-interest payment and exact future/present-value examples. Calendar checks handled leap day, month-end movement, and DST gap/overlap diagnostics. Markdown Mode accepted prose with embedded calculations. Find, editing Undo without reference rewrites, content search, Quick Ganit's Command-Return, and a 200-item $20,100 subtotal worked. Calculation source survived the normal app restart.

No crash was observed. The 200-item workflow is a successful exploratory test, not a latency benchmark. No purchases, real financial decisions, system preference changes, or communications to other people were performed.

Computer Use's accessibility tree did not expose individual answer elements or interpretation-popover contents in the snapshots inspected. The source nevertheless implements custom accessibility children and rotors. **This is a validation gap, not a confirmed VoiceOver defect.** Verify by listening with VoiceOver and inspecting the live accessibility hierarchy before filing a blocker.

Not covered: real IMEs, right-to-left layouts, listening with VoiceOver, physical multi-display/Spaces behavior, global shortcut conflicts, Services/Shortcuts callbacks, destructive Trash/recovery workflows, offline/rate-fetch failure injection, printer output, or a complete PDF/HTML export review. Focus and clipboard failures while Ganit was inactive were excluded from the defect list because the tool context affected the result. Screenshots are app-window captures and can omit popover portions outside the window.
