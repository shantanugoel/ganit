# AI as part of the calculator: experience plan

Date: 2026-10-20
Status: Design approved. M-1 (the Effort setting) and M0 (reconcile and freeze)
are complete; M1 and later are not started and no gate below them is complete.
M0's records are [ADR 0019](../adr/0019-ask-one-operation-four-outcomes.md) and
[the frozen Ask job contract](../design/ai-native/ask-job-contract.md), and the
harness this plan tells M1 to reuse is now merged into this branch. The legacy
assistant is still here; M5 removes it. See
[CHANGELOG](../../CHANGELOG.md) for released behaviour.
Prototype: [interactive concept](../design/ai-native/prototype.html) ·
[flow, shapes and decisions](../design/ai-native/index.html)
Companion records: ADR 0012 (current assistant, amended), ADR 0018 (checked
suggestions, superseded in part), ADR 0019 (Ask)
Prior plan: `docs/plans/ai-expression-suggestions.md` and ADR 0018, both now on
this branch, describing the engine snapshots, candidate checker, bounded
harness, and tests that were written on
`codex/ai-expression-plan`. Read them, and
[assistance contracts](../engine/assistance-contracts.md), before M1.

## 1. Outcome

Make people feel that **Ganit understands and manipulates their calculations
better**, not that Ganit has a chatbot in it.

One operation, **Ask** (⌘⇧A), reaches the model. Its *outcome shape* decides
what the user must do:

| Outcome | User action | Durable? |
| --- | --- | --- |
| Explain card | none, Esc closes | no |
| Answer card | none, Esc closes | no |
| Proposal | **Apply ⌘↩** | becomes ordinary source |
| Assumption value | optionally edit the number | yes, marked `AI` |

There is no chat surface, no mode switch, no AI panel, and no AI state that
survives on screen after the job ends.

## 2. Non-negotiable rules

These are the acceptance criteria for every milestone. A change that breaks
one is a design change, not an implementation detail.

1. **Ganit is the only calculator.** No model-supplied number is ever an
   answer, never a literal inside an expression, and never a displayed answer. A
   model may only *name* a fact, which becomes a declared, marked, user-editable
   value (§6). The engine calculates every preview and accepted result, on a
   frozen snapshot, with no alternate evaluator.
2. **The answer column is Ganit-only.** AI output lives in cards or in source.
   This removes today's purple display answers and the
   `evaluation.unusableAssistantAnswer` reference path.
3. **Detect locally, send on request.** A passive affordance is computed on
   device. Nothing leaves the Mac until ⏎ in the Ask bar. Automatic requests
   are out of v1 (§11); the automatic path in ADR 0012 is removed, because
   ADR 0012 already claims the assistant makes "a request nobody makes without
   asking for it".
4. **Source changes are always previewed** and applied by one explicit action,
   as one named Undo step (`Apply AI change`), through the existing source
   coordinators. No AI-specific undo stack, no second document source.
5. **Read-only outcomes are free and transient.** Explain and Answer cards
   cannot be referenced, are not saved, and do not accumulate a thread.
6. **Never preview what Ganit rejected.** A proposal that does not parse and
   calculate is a failure, not a dimmed preview.
7. **Explain is Ganit-first.** Expression, result, dependencies, applied
   grammar rule, assumptions, and diagnostics come from the engine. The model
   is an explicit fallback for intent-level questions. The card states whether
   anything was sent.
8. **Provenance marks the origin of a value**, not who typed it, and not which
   keystrokes produced a formula. AI-written structure that Ganit verified is
   unmarked. An AI-supplied fact is marked permanently until the user edits it,
   at which point the mark disappears.
9. **Context is minimal and disclosed.** Selection plus the lines it
   transitively reads; a sheet-level ask sends the sheet as far as the harness
   target limits allow — 12 lines, 8 KiB, contiguous, no table block. The
   `Context ▸`
   disclosure shows the exact lines before they go. Existing transport
   protections remain: HTTPS except loopback, redirect refusal, ephemeral
   session, keychain key, `User-Agent: Ganit`.
10. **The product is complete without AI.** No model configured means no
    affordance, a disabled menu item, and no behavioural difference elsewhere.

## 3. Relationship to `codex/ai-expression-plan`

That branch solved the hard parts: read-only engine snapshots, shadow
evaluation, the bounded harness, budgets, fingerprints, and stale checks. This
plan reuses them and changes only what the prototype contradicts. **Do not
start a second harness, snapshot adapter, or proposal state machine.**

| Prior decision | This plan | Basis |
| --- | --- | --- |
| Model returns source proposals; engine calculates all results | **Adopt unchanged** | identical |
| Never a model-supplied number as the answer | **Adopt unchanged** | rule 1 |
| Bounded repair budget counted with all follow-ups | **Adopt**; default 2, Settings 0–3 | prototype scenario 4 |
| Apply through existing coordinators, one Undo transaction, stale recheck | **Adopt unchanged** | rule 4 |
| No special source syntax, no fenced AI block, no live English model | **Adopt unchanged** | rules 2, 8 |
| Permitted-scope context package with renewed consent | **Adopt**, presented as the `Context ▸` disclosure | rule 9 |
| State machine, in-memory bounded cache, injected fake transport | **Adopt**; the persisted `AssistantAnswers.json` answer cache is retired with the legacy path | §8 |
| **Model may not supply a missing fact; ask instead** | **Amend** — see §6 | the density case is the product's own flagship example |
| Optional automatic suggestions in a session-enabled area | **Defer** to post-v1 (§11) | rule 3; ship request-only first and measure |
| Command named **Suggest Expression** | **Amend** to one command, **Ask Ganit…** | several verbs would force the user to classify intent up front |
| Question at most one clarification at a time | **Adopt**, capped at 2 per Ask, answered inside the same bar | prototype scenario 5 |

The §6 amendment is the only substantive product disagreement. **Resolved at M0
in favour of the amendment:**
[ADR 0019](../adr/0019-ask-one-operation-four-outcomes.md) carves ADR 0018's
decision 1 back to arithmetic and intent, and lets a model *name* a world fact
that must then become a declared, marked, user-editable value. The assumption UI
is not cut from v1. Its four divergences from the harness are written into
[the job contract](../design/ai-native/ask-job-contract.md).

## 4. Surfaces

Four doors, one room. Every door opens the same Ask bar.

| Door | Where it lives |
| --- | --- |
| ⌘⇧A anywhere in the editor; **Calculate ▸ Ask Ganit…** | `MainMenu`, `SheetCommands` |
| Quiet `Ask` chip on the caret's failing/prose line only | answer overlay in `SheetTextView` |
| Trailing `Ask Ganit…` on the existing selection summary bar | `SelectionSummaryBar` |
| Right-click ▸ Ask Ganit… | `SheetTextView.menu(for:)` |

Cards reuse `InterpretationViewController` styling; the Ask bar reuses
Find-bar and completion chrome. New chrome is limited to the Ask bar, the
proposal panel, the failure card, and two decorations in `LineDecoration`
(the `AI` badge, the dependency dot). Colors, type, spacing and symbols come
from `VisualStyle`; a purple `interpretation`-adjacent token is added, no new
palette, no animation, no custom material.

## 5. Interaction contract (conceptual)

Named here so the UX is provably implementable. **Not a schema, not a class
hierarchy** — freeze the shape in M0 with the prior branch's harness author.

An Ask job receives: target (caret line / selection / sheet), the typed
instruction, the disclosed context lines, engine facts for those lines
(parse state, diagnostics with ranges and fix-its, dependency membership,
value kinds, function catalog), and the model identity.

It yields exactly one of:

- **proposed source change** — line additions, replacements and deletions
  addressed by `LineID`, optionally with interpretation comments and named
  assumption declarations;
- **explanation** — engine-sourced, or model-sourced when the question is
  about intent;
- **answer** — a single unverified value for a question with nothing to
  calculate; shown once, never referenced;
- **clarification request** — one question with an optional suggested set;
- **external assumption** — a named fact with a human-readable basis, which
  must materialise as a declared value;
- **failure** — with a reason classifiable as `not-ganit-source`,
  `rejected-by-engine` (carrying the diagnostic), `unreachable`, or
  `no-useful-answer`.

Any proposal is handed to the existing candidate checker on a shadow copy of
the sheet. Rejection feeds the diagnostic back for a bounded repair turn. The
user sees `Ganit is checking…`, plus one quiet line
(*Ganit asked the model to fix its first attempt*) when a second turn starts.
Per-line opt-out, partial apply, and blocked apply on newly introduced
failures follow the prior plan §7 verbatim.

## 6. External assumptions (the amendment)

Allowed only when **all** hold:

1. The fact is world knowledge, not user intent. Tax rate, currency of a
   salary, or a budget figure is intent → ask. A physical constant, a typical
   rate, or a material property may be assumed.
2. It materialises as a declared, named, plain-text value on its own line —
   never a literal embedded in an expression, never a displayed answer.
3. It carries a provenance comment Ganit writes and the user can delete:
   `// AI: density of water at 4 °C · <model> · <date>`, following the
   existing `// Manual answer; original:` precedent.
4. `LineDecoration` renders that comment as the `AI` badge, and every line
   that transitively reads it gets a leading purple dot, derived from the
   engine's existing dependency provenance. `View ▸ Mark AI-derived answers`
   toggles the dots; the origin badge never hides.
5. Clicking the badge opens the assumption card: value, what it is, model and
   time, which lines use it, `Change value…`, `Remove` (which previews what
   breaks), `Copy`.
6. Editing the value removes the badge and the downstream dots.

If the classification in (1) is uncertain, **ask**. The bar's rule of thumb is
stated in Help: *Ganit asks when only you know; it assumes and marks when the
world knows.*

## 7. Removals

Land these with the milestone that replaces each behaviour, not before.

| Remove | Replaced by |
| --- | --- |
| `ask_assistant(prompt)` grammar, `{…}` placeholders, `AssistantPrompt` | assumption values and proposals |
| Automatic 1.2 s line requests (`assistantPause` path) | the passive `Ask` chip |
| AI values in the answer column, `AnswerCell.isAssisted`, `VisualStyle.Color.assisted` display path | cards and source only |
| **Ask Assistant**, **Change Answer…**, **Cancel Request** menu items | one **Ask Ganit…** (Esc in the bar cancels) |
| `evaluation.unresolvedAssistantPrompt`, `evaluation.unusableAssistantAnswer` | ordinary reference errors |
| `AssistantAnswerStore` persistence of replies by asked text | bounded in-memory proposal cache |
| Help-search pointer to `ask_assistant(…)` | Ask |

`AssistantSettings` keeps the endpoint, model and keychain key, and gains
`Repair attempts` (0–3), `Mark AI-derived answers`, and `Effort`.

**Effort** (M-1, landed) is how hard a model is asked to think: Off, Low,
Medium, High, Extra high, Max, or Custom with a free-text word. It is stored in
preferences as one key (`AssistantEffort`), defaults to **Medium**, and goes out
as the request's `reasoning_effort`. Off sends no word at all, and a Custom with
nothing typed in it is Off, because a field the server has never heard of is
likelier to be accepted when absent than when empty or wrong. It is a preference
for the server and nothing else: no Ganit behaviour depends on it, and every
Milestone gate below still holds with it set to any value. Every Ask request
from M1 on carries it the same way the line-level request does.

## 8. Ownership

| Area | Files | Work |
| --- | --- | --- |
| Engine | `SheetCalculator`, `SheetSource`, `LineOutcomes` | reuse the prior branch's read-only snapshot adapter and candidate checker; expose dependency membership for dots |
| Data | `GanitData/Assistant*` | reuse prior transport; replace value-reply decoding with proposal decoding; retire `AssistantReply` value hygiene into a proposal hygiene step |
| Editor | `SheetTextView`, `SheetEditorViewController`, `AnswerCell`, `LineDecoration`, `SelectionSummaryBar`, `VisualStyle` | Ask bar, chip, proposal panel, cards, badge, dot |
| Source apply | `SheetSourceCoordinator`, `TableSourceCoordinator` | one named Undo transaction; no new document source |
| Chrome | `GanitWorkspaceUI/MainMenu`, `AssistantSettingsController` | Ask command, Settings fields, menu removals |
| Quick Ganit | — | untouched in v1 |

## 9. Milestones and exit gates

**M-1 — Effort.** Add the reasoning Effort setting to `AssistantSettings`, the
Settings window, and the request, with its own tests, before any Ask surface
exists. *Gate:* done 2026-10-21 — the popup offers Off/Low/Medium/High/Extra
high/Max/Custom…, Medium is the default, Custom sends the typed word, Off and an
empty Custom send no `reasoning_effort` at all, and `NetworkPrivacyTests` names
every key in the body.

**M0 — Reconcile and freeze.** *Done 2026-10-21.* Decided §3's amendment in
writing; superseded or amended ADR 0012 with a new ADR naming the Ask outcomes,
the assumption carve-out and the context disclosure; froze the job contract,
`LineID` addressing for proposals, and the classification rule in §6.
*Gate:* **passed** — [ADR 0019](../adr/0019-ask-one-operation-four-outcomes.md)
is accepted; the prior branch's harness is reused as merged code, with its six
divergences written down in
[the job contract](../design/ai-native/ask-job-contract.md).

**M1 — Ask bar and proposal, engine-verified.** *In progress 2026-10-21.* Bar,
chip, selection bar entry, right-click. Proposal panel with live shadow answers,
per-line opt-out, Apply as one named Undo step, stale checks, Esc cancel. *Gate:*
the `loan` and `trip` scenarios pass against a fake provider, including ⌘Z
restoring exact bytes and selection. **Passed in the harness:** the bar opens
from all four doors; the typed words go as a task note with `reasoning_effort`;
`Context ▸` renders the disclosure in words, with the exact bytes one click
away; Apply is one Undo step named *Apply AI Change* and ⌘Z restores bytes and
selection (`loan`, `trip` fixtures, fake transport); Esc closes; nothing is sent
without ⏎; the `Ask` chip appears on the caret's failing line and only there,
and makes no request.

**Two defects found in the built app, both fixed:**

1. The Ask bar covered the source, line numbers, and results. Its background
   fill used the full dirty rectangle. AppKit can extend that rectangle outside
   the view bounds. The bar could thus paint over the sheet after the sheet
   had drawn. The fix limits the fill to the intersection of the dirty rectangle
   and the bar bounds. A blue sheet background also disappeared with the old
   code. The fixed app keeps the source and results visible with the bar open.
   The drawing test supplies a dirty rectangle larger than the bar and checks
   that pixels outside the bar do not change. The window capture test uses
   ScreenCaptureKit with no redraw fallback. It checks three open and close
   cycles in light and dark appearance. To run this desktop check, set
   `GANIT_WINDOW_CAPTURE_TESTS=1` and run
   `swift test --filter SheetSuggestionTests.theSourceStaysInkWhileTheBarIsOpen`.
   Screen capture permission is required. The old `cacheDisplay` check was
   removed because it redraws the views and cannot detect this failure.
2. The chip was drawn where it should be but was inert: its hit-test compared
   the text view's rect against the overlay's own coordinate space, so clicks
   fell through to the text and moved the caret. Fixed by converting between the
   two spaces in `hitTest`, `mouseDown`, and the cursor rects; verified by
   clicking the chip in the built app and watching the bar open.

**Also outstanding:** per-line opt-out — the harness produces a single `T1`
replacement, so declining one proposed line means rebuilding the replacement and
re-checking it, which is not built yet. Until it is, the bar offers
all-or-nothing Apply.

**M2 — Validation and repair.** Diagnostic-fed repair turn within the shared
budget, the two visible status lines, the failure card with the four reason
classes, and `Show what the model meant`. *Gate:* `repair` passes with
injected `unknownFunction`, malformed-output and timeout fixtures; no path
renders an unparseable proposal.

**M3 — Clarification and assumptions.** In-bar question with crumb and
suggestions, 2-question cap, resume-in-place; assumption declarations,
provenance comment, badge, dependency dots, assumption card, `Change value…`
and `Remove` preview. *Gate:* `prose`, `clarify` and `water` pass; editing an
assumption recalculates with zero requests; editing its value
clears all marks; and `AssistanceSemanticPolicy`'s option-less `missing_density`
choice is gone, replaced by an assumption with a basis, so the water example
reaches Apply.

**M4 — Ganit-first explain and fix.** Engine-sourced explain card reusing the
interpretation card, `Fix it` hand-off on diagnostics, explicit "nothing was
sent" statement. *Gate:* `explain`'s three frames pass; the card is correct
for `line N` renumbering failures.

**M5 — Removals, privacy, docs, release gates.** §7 deletions, Settings
changes, privacy statement and Help rewritten for the disclosed context model,
VoiceOver labels for chip/badge/dot and every panel, `VisualStyleTests` and
network-privacy tests updated to the new wire shape. *Gate:* the whole suite
green, no AI code path reachable with the setting off, and the shipped
behaviour matches the prototype.

## 10. Verification

- **Network bytes:** extend `NetworkPrivacyTests` to assert the new request
  carries disclosed context lines, the instruction, and the model name only.
- **Undo:** byte-for-byte restore, selection restore, one step, correct name.
- **Staleness:** target edits during a request mark stale; late replies with a
  changed fingerprint are ignored; unrelated edits may keep a proposal.
- **Determinism:** after Apply, editing inputs performs zero requests (assert
  on the fake transport's call count).
- **Provenance:** badge/dot follow the dependency graph through insertion,
  deletion, line renumbering, and divider clearing; editing a value clears
  them.
- **Failure:** no proposal is ever shown for source the engine rejected;
  every reason class has a distinct, non-technical message.
- **Accessibility:** chip, badge and dots are reachable and labelled; the
  failure and question states are announced; nothing relies on colour alone.
- **Performance:** Ask never runs on the editor's evaluation worker; typing
  latency gates in `GanitBenchmarks --editor` stay green.

## 11. Deferred, deliberately

Proposal diff editing beyond per-line opt-out · Ask in Quick Ganit, Services,
Shortcuts and `ganit://` · streaming and progressive proposals · multi-turn
sheet-wide re-modelling beyond the question cap · table-block targets ·
assumption freshness, citation and source lookup · model routing, per-sheet
model choice and cost display · cross-sheet learning of user conventions ·
proposal history and "undo everything AI did in this sheet" · automatic
suggestions (post-v1, only if request-only usage shows the need).
