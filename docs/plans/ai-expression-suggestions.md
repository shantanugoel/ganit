# AI expression suggestions: product and implementation plan

Date: 2026-10-13

Status: Implementation is in progress. No phase exit gate is complete.

Selected direction: Option 2, an editor that suggests calculation expressions
and repairs. This plan does not introduce a live English document model.

## 1. Outcome

Let a person write a numerical intention in ordinary English. Suggest a
Ganit expression at that location. Let the person inspect its meaning and
result, then accept or dismiss it. Also suggest repairs to existing formulas.

The AI proposes source edits. Ganit calculates all preview and accepted
results with its existing engine. Accepted expressions become ordinary sheet
source. Later number edits use local calculation and require no AI request.

A harness is the application code around the model. It prepares context,
limits requests, checks proposals, returns errors for repair, and controls
application of an edit. A prompt alone is not the harness.

The product must distinguish three statements:

- The expression parses and calculates.
- The expression follows the supported rules and supplied inputs.
- The expression represents what the person intended.

The harness can check the first statement and parts of the second statement.
It cannot prove the third statement for arbitrary English. Keep material
choices visible. Do not promise that an AI suggestion is always correct.

## 2. Decisions for the first release

| Question | Decision | Reason |
| --- | --- | --- |
| Must the user enter a special block? | No. Use a command on a line or selection. | The person can keep working in the editor. |
| Does enabling a provider enable automatic requests? | No. Manual suggestions are the default. | Connection setup does not grant permission to send each draft. |
| Can suggestions appear automatically? | Yes, inside an area the user enables for the current session. | The scope and request conditions remain visible. |
| What starts an automatic request? | A completed line or paragraph, followed by an idle period. | A typing pause alone does not establish completion. |
| Can AI change source automatically? | No. Apply only after the person accepts a preview. | An incorrect interpretation cannot silently change working. |
| Can AI supply the displayed answer? | No. The engine supplies the answer. | Proposed source and calculated results stay connected. |
| Can the model add a missing fact? | No. Ask for the missing input. | A guessed rate or density can produce convincing arithmetic. |
| Is the whole sheet sent? | Only when the person explicitly selects that scope. | Use the smallest permitted context that can support the task. |
| Is a long conversation required? | No. Use an inline suggestion and at most one clarification at a time. | The calculation remains the main surface. |

Keep special syntax out of the first release. A `?` prefix or fenced AI block
would add parser, Markdown, copy, export, and reference rules. It would also
require people to learn syntax before they can request help. A visible,
session-only area gives the scheduler a clear scope without these changes.

Test this decision with users. A typed marker can be a later shortcut if
users need it. It must not become the only way to request a suggestion.

## 3. User interaction

### 3.1 Create an expression

Expose **Calculate > Suggest Expression** and the same action in the
selection menu. Show a quiet action beside a completed line that local
analysis identifies as a possible calculation request. Showing this action
does not call AI. Select its keyboard shortcut after a menu conflict check.

Example source:

```text
bill = 2,400 INR
Add a 10% tip to the bill, then split it four ways.
```

Example suggestion:

```text
share = (bill + 10%) / 4
Calculated preview: 660 INR each
Uses bill: 2,400 INR. Tip applies to the bill. Four equal shares.
```

Show the proposed expression beside the target. A compact card contains the
result, input references, material assumptions, and the source edit.
Actions are **Use Expression**, **Show Working**, and **Dismiss**.

For an existing expression, preserve its label, variable name, and comment
unless the person explicitly includes those parts in the edit scope.
For an English request, replace the target with the accepted expression.
Keep the original request as a source comment. Insert a calculation below
is a secondary action. In ordinary mode, preserve the request as a comment
so that it does not remain a failed calculation. In Markdown mode, preserve
it as prose only when the existing line classifier permits that form.

Number edits to the accepted expression calculate locally. The original
request comment is a record, not a second editable calculation. This is
Option 2; it does not require two synchronized representations of meaning.
Mark retained request comments as historical records in the context package.
Do not treat their old quantities as current inputs or active task rules.
The user can explicitly select a historical record for an intent check.

### 3.2 Repair an expression

Use native diagnostic fixes first. A locale rewrite, trailing equals sign,
or known syntax fix can appear without a model request.

For an AI repair, show the before and after expressions and their results.
Keep the current diagnostic visible until the source edit is accepted.

Example task:

```text
// Find volume from the mass and density.
mass = 250 g
density = 0.8 g/ml
volume = mass * density
```

Propose `volume = mass / density`, with a preview of `312.5 ml`.
The explanation identifies the dimensions of multiplication and division.
The expected volume dimension comes from the task, not the variable name
alone. Without that task, show the expected dimension as a choice to review.

Also permit an explicit **Check Against Note** action on a valid formula.
For example, a selected note can say tax applies to items only. A formula
that also taxes shipping can then receive an intent-conflict suggestion.
Label this as a possible conflict. It is different from an engine error.

### 3.3 Complete working

Offer expressions that use visible variables when the person requests a
completion or enables automatic suggestions in that area. Resolve names to
actual declarations. Highlight the references on focus.

Do not produce generic advice or a list of unrelated next tasks. Limit the
suggestion to the active target and stated goal.

### 3.4 Review and keyboard behavior

- A model result appears only in a card marked **Suggestion**.
- The normal answer column continues to show the accepted calculation.
- **Arithmetic checked** means the engine calculated the proposed source.
- **Needs choice** means a material interpretation is unresolved.
- **Possible intent conflict** means the written rule and formula may differ.
- A suggestion does not enter totals, exports, or ordinary Copy Result.
- Tab accepts only when the suggestion control has explicit focus.
- Escape dismisses the suggestion before it dismisses Quick Ganit.
- Return retains normal editor behavior. It does not accept a suggestion.
- Do not move focus, scroll to a proposal, or announce each typing event.
- Expose the proposal, edits, status, and references to VoiceOver.

After acceptance, use ordinary answer formatting and reference behavior.
Keep the original request and declared assumptions available in source.
Use a concise source comment for every user-approved estimate that affects
an expression. Preserve that comment in Copy with Working and exports.

## 4. When to call AI

### 4.1 Manual requests

The Suggest Expression command creates one logical job. A job consists of
an initial request and any permitted context or repair requests.
One wire request is one outbound provider request, including a format fallback.
Freeze the target after text composition commits. Show the context scope
before the first request with expanded context. Do not send a partial IME
composition. An explicit request does not enable automatic suggestions.

Use the selection as the target. Without a selection, use the active line.
Large selections need a visible size error or a smaller-scope choice.
Do not silently cut off selected text.

### 4.2 Optional automatic suggestions

Provide **Suggest in This Area**. It marks the current line or paragraph
with a small AI scope label. It is off by default. Its state ends when the
sheet closes, the area is removed, the provider changes, or Ganit quits.
It does not resume on launch. This state is not sheet grammar.

All of these conditions must hold before an automatic job starts:

1. The provider is ready, and the user accepted the expanded-context policy.
2. The target is inside the visibly enabled area of the active editor.
3. The user changed that target after enabling the area.
4. A line or paragraph completion event occurred after that edit.
5. Text composition ended, and the editor has been idle for 1.2 seconds.
6. Local parsing and completion checks do not show unfinished input.
7. A local fix or an already valid expression does not satisfy the task.
8. The same target and context have no current proposal or terminal outcome.
9. The request limits permit a new job.

A line completion event is Return or an explicit move out of that line.
A paragraph completion event is a paragraph boundary after its last edit.
Idle without a completion event makes zero automatic requests. Typing more
text clears that target's completion event. Pasting multiple lines does not
complete every pasted line. Require an explicit request or a subsequent
completion event for the active target.

Suppress requests during undo, redo, file open, autosave, scrolling,
selection-only changes, autocomplete insertion, provider setup, and IME
composition. Accepting a suggestion also suppresses automatic requests for
the resulting expression. Editing its values uses local calculation.

Incomplete expression checks include parser severity, unmatched delimiters,
and a trailing operator. English completion checks are conservative local
rules. They need no AI classifier. A sentence can still be ambiguous after
these checks; the response and review rules handle that ambiguity.

### 4.3 Limits and cancellation

These are initial limits to test, not measured usability results:

| Limit | Initial value |
| --- | --- |
| Active managed model jobs | One per provider across Ganit windows |
| Automatic pending jobs | One latest target; do not queue every edit |
| Automatic jobs | Two per minute and twelve per enabled area session |
| Automatic wire requests | Six per minute, including repairs and format fallback |
| Minimum automatic job interval | Fifteen seconds |
| Model requests in one job | Three total |
| Per-request timeout | 30 seconds for remote; 120 seconds for local |
| Job deadline | 90 seconds for remote; 180 seconds for local |

All retries count against the job and session limits. A timer does not poll
for work. Arm it only after an eligible event. Once a limit is reached,
show **Automatic suggestions paused**. The explicit command remains
available, subject to provider limits and the one-active-job rule.

Manual jobs take priority over automatic jobs. Do not wait behind a stale
automatic draft. Cancellation ignores late replies. It cannot recall text
already sent or guarantee that a provider stops processing that text.
Do not run automatic network retries after transport failures. Explicit
Retry creates a new job. Stop cancels timers, pending work, and active jobs.

## 5. Context package

### 5.1 Source and engine evidence

Build one immutable snapshot from the same evaluated source generation as
the target. Keep the complete shadow sheet local. Send only permitted
context. The context inspector must show the exact source data that will
leave the Mac, including every repair or context follow-up.

| Data | Purpose |
| --- | --- |
| Target handles and exact source | Identify the permitted edit, without model-supplied byte offsets. |
| Attached task notes and heading | Supply the numerical goal and explicit rules. |
| Matching visible symbol records | Resolve names, values, kinds, and declaration origins. |
| Referenced declaration and dependency records | Preserve meaning through custom functions and references. |
| Native diagnostics and source spans | Identify parser and evaluation errors precisely. |
| Capabilities and checked examples | Restrict output to grammar that this build supports. |
| Evaluation settings | Preserve number syntax, currency meaning, angles, dates, and precision. |
| Existing result facts | Show exactness, rate provenance, failure origins, and dimensions. |
| Input and relation evidence handles | Ground quantities and proposed interpretations in supplied text. |

Serialize values from typed engine values. Do not serialize only the rounded
answer string. Preserve rational numerator and denominator, decimal scale,
currency code, quantity kind and dimension, date zone, and approximation
status as applicable. Keep user source beside the canonical value.

Freeze `now`, calendar, time zone, dollar currency, angle mode, locale,
rounding, custom definitions, and cached currency rates for a preview.
Do not fetch rates or other data while validating a suggestion.

### 5.2 Context selection and permission

The default scope permits the target, its attached task notes, and relevant
visible declarations. Attached notes are the contiguous comment lines
immediately before the target and the nearest section heading. Show them
in the inspector; do not silently include distant paragraphs.

Use deterministic local name matching to build a small symbol inventory.
For formula repair, include its parsed references and required definitions.
For English, include direct name matches and locally ranked candidate names.
Show all selected records before transmission. Ranking is not proof that
a symbol is the intended reference.

An uncertain reference, such as "the amount above", needs either one clear
permitted candidate or a clarification. Do not substitute a numeric value
while hiding its source. Prefer a live reference over a copied literal.

The model can request additional context through a bounded outcome. If the
record is already in the permitted inventory, return it within the job
budget. Otherwise show **Include More Context** with the proposed records.
Send the new records only after the user includes them. Do not silently
search the library, definitions file, clipboard, other applications, or web.

Visible definitions can be used, but the full definitions sheet is not sent
by default. A selected table formula can receive named cells, ranges, or
column rules from its permitted context. It does not authorize all rows.

### 5.3 Initial size bounds

- Target source: at most 8 KiB and twelve physical lines.
- Context source and records: at most 24 KiB and sixty-four symbol records.
- Encoded request body: at most 64 KiB, including the grammar instructions.
- Decoded provider payload: at most 256 KiB.
- Proposal content: at most 32 KiB.
- Candidates: at most three. Each replacement: at most 4 KiB and sixteen lines.
- Clarifications: one question, with at most three choices or a missing input.

Count UTF-8 bytes. Preserve complete tokens and records. If a required
dependency will not fit, request a smaller scope or report the limit.
Do not omit it and let the model guess. Select capabilities for the task
from one generated catalog. Expand that catalog locally within these bounds.

## 6. Harness protocol and checks

### 6.1 Instruction and capability catalog

Generate the catalog from the engine's grammar, functions, signatures,
unit catalog, diagnostic codes, and current feature flags. Add checked
examples for percentages, money, rates, references, and date arithmetic.
Version the catalog and examples with the build. Avoid a second hand-written
parser or list of supported functions in the prompt.

The instruction tells the model to propose bounded source edits, cite
supplied evidence, ask when an input is missing, and return the strict
response schema. Source text and comments are data. They cannot grant tool
access, enlarge scope, change instructions, or authorize an edit.

The model receives no shell, browser, file-write, settings-write, or generic
network tool. Engine inspection operations are local application functions.
The first implementation can use ordinary JSON messages. It must not depend
on provider-specific tool calling or a specific model.

### 6.2 Response contract

Accept one of four outcomes: `proposal`, `clarify`, `need_context`, or
`unsupported`. Freeze a versioned JSON schema in M0. Reject unknown outcome
types, invalid field types, unknown fields, extra text, and oversized values.
Do not recover an expression from a model's reasoning text or last sentence.

Every proposal candidate includes edit handles, replacement source, symbol
bindings, literal evidence, relation evidence, and declared assumptions.
A short summary is explanatory text, not engine evidence. There is no
model-supplied calculated-result field and no confidence percentage.

This is an illustrative response for the bill example. `T1`, `S1`, and the
evidence handles are created by Ganit. The schema is frozen during M0.

```json
{
  "kind": "proposal",
  "candidates": [
    {
      "id": "C1",
      "edits": [
        {"target": "T1", "replacement": "share = (bill + 10%) / 4"}
      ],
      "bindings": [{"symbol": "bill", "source": "S1"}],
      "literals": [
        {"text": "10%", "evidence": "E1"},
        {"text": "4", "evidence": "E2"}
      ],
      "relations": [
        {"rule": "tip_on_bill", "evidence": "E3"},
        {"rule": "equal_split", "evidence": "E4"}
      ],
      "assumptions": [],
      "summary": "Add the tip, then divide into four equal shares."
    }
  ]
}
```

The local evidence table maps `E1` to `10%`, `E2` to `four`, and the relation
handles to the corresponding request phrases. A bounded English-number
conversion rule can map `four` to `4`. Declare its supported forms in the
catalog. Unsupported number words require clarification.

Ganit validates the evidence mapping independently. Every parsed numeric
literal needs source evidence or a named, permitted structural constant.
Examples of structural constants are the multiplicative identity and the
twelve periods used for an explicit nominal annual-to-monthly rate rule.
These constants are permitted only in the matching expression structure.
The model cannot invent a price, tax rate, density, or exchange rate.
Derived amounts must remain expressions, rather than model-computed literals.

### 6.3 Validation sequence

Run these checks on a worker, before an applicable preview exists:

1. Check the response schema, length bounds, and outcome.
2. Check each edit handle against the authorized target and base snapshot.
3. Check literal evidence, symbol origins, and complete relation records.
4. Apply the candidate to a local shadow copy with the normal source editor.
5. Parse with the same names, definitions, grammar, and context as the sheet.
6. Inspect the expression tree for unsupported or disallowed operations.
7. Evaluate with the existing sheet or table engine and normal resource limits.
8. Check result kind, units, expected dimensions, and explicit task constraints.
9. Check material ambiguity rules and compare the proposed relations with them.
10. Calculate the local effect on references and dependent results.
11. Build the preview from engine output and validated source records.

Check candidate dependencies too. Reject `ask_assistant` in the candidate,
in called custom functions, or in required dependencies. Do not consume
an unreviewed model value as validation evidence. Reject unresolved facts,
new global definitions, settings edits, new manual currency rates, and
references outside the permitted source scope.

Use engine errors for division by zero, invalid domains, type errors,
missing rates, table errors, and resource limits. Do not change an input
to make a failing expression calculate. A domain error can be the correct
result of the user's inputs. Return an explanation or ask for a missing
constraint instead of fabricating a successful result.

If a result has a legitimate approximate value or uses a cached rate,
retain its approximation and provenance. Native ambiguities with no selected
meaning cannot be bypassed by a candidate that silently chooses one meaning.

### 6.4 Semantic checks

Create a small, versioned registry of high-impact ambiguity rules. Start
with profit basis, tax inclusion and tax base, rate period, date ambiguity,
equal split versus exclusions, and mass-volume conversion with missing density.
Run its applicable checks independently of the model's declared assumptions.

For example, "20% profit" on a 1,000 INR cost requires a choice:
20% of cost gives 1,200 INR; 20% of selling price gives 1,250 INR.
The harness must not present either candidate as settled without that choice.

Compare constraints with parsed structure where possible. A note saying
"tax applies to items only" can constrain the tax base. A request for
millilitres constrains the expected result dimension. Evidence handles
alone do not prove that the English was interpreted correctly.

Keep all assumptions visible. A user selects a material choice before Apply
becomes available. If the harness cannot check a relation fully, describe
the interpretation for review. Do not label it verified.

### 6.5 Bounded correction

The first response can lead to a local check failure. Return its stable
error code, exact source span, expected type or dimension, native fix,
and the minimum relevant context. Request a corrected candidate.
The feedback contains engine facts, not private model reasoning.

Use at most three model requests in the job: one initial request and up
to two follow-ups. A context response, repair, or response-format fallback
consumes a follow-up. No hidden request occurs outside this budget.
Stop on repeated candidate source, repeated failure without new evidence,
cancellation, timeout, budget exhaustion, or provider failure.

Schema-output support is optional. If the provider rejects the requested
format, one plain-JSON request is permitted within the same budget.
The decoder remains strict. Never relax validation to obtain an answer.

A successful repair still needs user acceptance. On exhaustion, leave
source intact and show a short outcome with Retry or Edit Request.

## 7. State, cache, and application of edits

Use these states: idle, preparing, requesting, checking, repairing,
needs-context, needs-choice, ready, stale, applied, dismissed, cancelled,
failed, and paused. Each job has one terminal outcome. A follow-up continues
the same job and its budget. User submission of a clarification starts a
new job with the expanded intention and current source.

A fingerprint is a digest of the context that affects a proposal.
A stale proposal has a target or context that no longer matches its snapshot.

The request key includes target source, task notes, permitted scope,
declaration origins, dependency values and definitions, evaluation settings,
and the relevant rate snapshot. It also includes catalog version, schema
version, endpoint, and model.
Include table and implicit aggregate membership when they affect meaning.
Do not key a reply only by the English line or its displayed values.
For a checked candidate without time or currency dependencies, exclude
clock ticks and unused rate updates from its reuse fingerprint. Keep the
full frozen context for local validation. A time or rate change can still
require local preview recalculation for a candidate that uses those values.
Track dependencies in the interpreted task as well as the expression tree.
For example, a date derived from "today" must retain its clock dependency.
Prefer the engine's date expression to a model-computed date literal.

Store only a bounded in-memory proposal cache in the first release. Initial
bounds are 128 entries and 4 MiB across the app. Keep terminal no-proposal
outcomes for that exact key. Do not persist transport failures as answers.
Do not store keys, requests, or replies in logs or analytics.

On any relevant edit, recompute the target's context fingerprint. Ignore
late responses with a different fingerprint. Unrelated edits can preserve
a proposal only if the target, reference identities, scope, and dependency
fingerprints remain valid. Otherwise show stale without automatically
starting another request. Local recalculation can refresh a preview when
only an existing referenced value changes. The proposed source must retain
the same validated bindings and interpretation.

Recheck all preconditions immediately before Apply. Check original source,
target identity, namespace, context, and edit boundaries. Use stable line
and table identities, with app-owned ranges. Model-supplied ranges are not
accepted. Unicode conversions use the existing source range types.

Apply source edits, comments, reference transformations, and selection
changes in one undo transaction. Evaluate the complete local effect before
Apply. For a rewritten referenced line, preserve the identity of its result
or transform references explicitly. Adding a comment must not retarget
references to that comment. If a multi-line rewrite has no unique mapping
for an existing external reference, require the user to resolve it.

Show new or changed downstream failures. Apply is blocked until a newly
introduced failure is resolved or the user explicitly includes that change
in a revised edit. Existing unrelated failures remain visible and do not
become evidence that a candidate is wrong.

Use `SheetSourceCoordinator` and current table edit coordinators. Do not
create a second document source or a parallel evaluator. Accepted working
uses current autosave, backup, print, and export paths. AI panel state and
session permissions are not durable calculation data.

## 8. Code boundaries

These names describe responsibilities. Freeze actual APIs in M0.

| Component | Responsibility |
| --- | --- |
| GanitEngine: assistance snapshot adapter | Read-only scope, typed values, dependency records, diagnostics, and catalog facts. |
| GanitEngine: candidate checker | Parse and evaluate shadow source with existing engine semantics. |
| GanitData: suggestion transport | Bounded request and strict response decoding; existing connection protections. |
| Suggestion coordinator | Context permission, scheduling, budgets, state, cache, cancellation, and repair. |
| GanitEditorUI: suggestion presentation | Inline edits, preview, reference focus, clarification, and responder actions. |
| Existing source coordinators | Apply checked edits and reference changes as one document transaction. |

Keep networking out of GanitEngine. Snapshot creation must not reevaluate
all sheets or read live settings. Existing public result records do not
expose all required traces; add a narrow immutable adapter. Do not let UI
or prompt code reconstruct hidden engine semantics from formatted answers.

Reuse the current HTTPS and loopback rules, redirect refusal, ephemeral
sessions, and keychain storage. Provider connection settings remain separate
from context and automatic-request permission. No provider health check or
example request runs just because a sheet opens.

## 9. Verification plan

Use an injected fake transport and recorded response fixtures first.
The tests must not read the user's provider settings or API key. Use a fake
clock and scheduler for call-count tests. Do not rely on real sleeps.

| Case | Required outcome |
| --- | --- |
| Bill of 2,400 INR, 10% tip, four equal shares | Checked expression gives 660 INR; all inputs and relations have evidence. |
| Mass 250 g, density 0.8 g/ml, expected volume | Repair gives 312.5 ml; multiplication fails the expected dimension check. |
| Same formula without a stated target dimension | Show the inferred intention for review; do not treat the name as proof. |
| 20% profit on a 1,000 INR cost | Needs choice; accepted prices are 1,200 or 1,250 INR for the selected basis. |
| Annual rate used as a monthly rate | Repair follows an explicit nominal-rate and payment-period rule, or asks. |
| Tax note excludes shipping | Proposed tax base respects the supplied rule; show total changes. |
| Undefined symbol or two plausible prior amounts | Need context or clarification; no guessed binding. |
| Mass to volume with no density | Ask for density; do not use a model's factual value. |
| Zero denominator, invalid date, missing rate | Preserve the error or ask for missing input; never invent a working value. |
| Comma-decimal locale, dollar meaning, angle mode, DST | Preview uses the frozen engine context and native ambiguity rules. |
| Rounded rational or approximate dependency | Exact typed value and approximation status survive the context package. |
| Variable redeclaration, divider, custom-function captures | Bind to the correct visible declaration and frozen dependencies. |
| Failed line or legacy AI dependency | No successful preview built from an unreviewed answer. |
| Valid formula requested for review | Intent check can run explicitly; automatic mode makes zero calls. |
| Unsupported function or recursive AI expression | Reject with a checked reason; bounded repair cannot add the capability. |
| Malformed JSON, unknown fields, oversized reply | Reject; no source or answer change. |
| Injection text, fake handles, unrelated edit, invented literal | Scope and evidence checks reject the proposal. |
| User dismisses, edits, undoes, or changes provider | Late reply cannot appear or apply under the old key. |
| English replacement inserts comments or changes line count | References retain their intended result; Undo restores everything once. |
| Apply causes a new downstream failure | Show its origin and prevent an unreviewed broken edit. |
| Table cell and column rule | Preserve identities and overrides; check affected rows locally. |
| Request deadline or provider failure | Stop the job; no hidden network retry or cached successful value. |

Required call-count scripts:

1. Ordinary typing with automatic suggestions off: zero requests.
2. Provider configured but no request permission: zero requests.
3. Long typing pause without a completion event: zero requests.
4. Incomplete formula or active IME composition: zero requests.
5. Open, undo, redo, autosave, scroll, or paste alone: zero requests.
6. Complete one edited target in an enabled area: one initial request.
7. Repeat the same source and context: zero additional requests.
8. Dismiss and revisit without a relevant edit: zero additional requests.
9. Accept a proposal and edit its numbers: zero requests.
10. Repair twice or use a format fallback: at most three requests in the job.
11. Several windows request automatically: one active job and one latest pending target.
12. Reach an automatic limit: pause visibly; no timed restart or queued burst.

Add independent expected formulas and constraints to the fixtures. A test
must not use the proposed expression as its own expected answer. Test
deliberately wrong but syntactically valid replies. Zero unsafe acceptance
in the fixture set is required; it is not proof for all possible English.

Before release, run opt-in model evaluations with synthetic data and a
separate configuration. Keep live model results distinct from deterministic
harness tests. Record model, endpoint, catalog, sample, and date. Evaluate
accepted correctness, clarification quality, repair improvement, and calls
per task. A benchmark must not count abstention as a correct calculation.

Then run task sessions with novices and experienced calculator users.
Include translation, repair, wrong suggestions, dismissal, and scope review.
Compare explicit requests with optional automatic suggestions. Measure task
completion, wrong acceptance, interruption, and avoidable calls. Adjust
timing and limits only from recorded evidence. Disable automatic release
if users cannot understand its scope or avoid repeated interruptions.

Retain the existing performance gates. Measure the same baseline commit
and candidate on the same hardware. Suggestion tasks must not block typing
or ordinary engine evaluation. Record disabled-mode and active-job results.
Verify minimum window size, light and dark appearance, keyboard-only use,
VoiceOver, text scaling, real IMEs, and Unicode edit ranges.

## 10. Implementation sequence and exit gates

The implementation has started. Complete the whole slice before marking a
phase done. A later phase does not replace an earlier safety requirement.

### M0: Freeze contracts and test data

- Define snapshot, target handle, evidence, response, and validation schemas.
- Define grammar catalog generation and the semantic ambiguity registry.
- Resolve shortcut conflicts and review the inline interaction with sample tasks.
- Specify the injection point for fake transport; no settings access in tests.
- Exit: checked fixture inventory, schema examples, and API boundaries are reviewable.

### M1: Build local context and checking

- Add the immutable assistance snapshot and exact value serialization.
- Add shadow-source checking, scope policy, evidence checks, and result constraints.
- Check full local reference effects with existing source transformations.
- Exit: the wrong-proposal fixtures fail correctly; no network path is necessary.

### M2: Build transport and the bounded harness

- Add strict outcome decoding, response limits, and provider-independent JSON support.
- Implement the correction loop, permission checks, deadlines, and cancellation.
- Add privacy tests that inspect the exact request body and every follow-up.
- Exit: fake requests demonstrate the full bounded loop and zero unauthorized context.

### M3: Ship the explicit editor interaction as a complete local test slice

- Add Suggest Expression, inline preview, choices, and source acceptance.
- Preserve comments, names, references, and one-action Undo.
- Support ordinary sheets, Markdown sheets, and Quick Ganit prose expressions.
- Exit: creation, repair, stale reply, keyboard, copy, save, and reopen workflows pass.

### M4: Extend scoped repairs to tables

- Support a selected cell formula and an explicitly selected column rule.
- Reuse table context, source identities, and existing edit coordinators.
- Check all affected rows locally. Show the effect and retained cell overrides.
- Keep table creation, bulk row edits, and automatic whole-table review outside this release.
- Exit: cell and column-rule fixtures pass with no unrelated source edits.

### M5: Add optional automatic suggestions

- Add the visible session area and completion-event scheduler.
- Add app-wide request accounting, duplicate suppression, and explicit job priority.
- Run the fake-clock scripts and task sessions before enabling this mode in release.
- Exit: all zero-call and request-bound cases pass; scope and interruption tests pass.

### M6: Replace the legacy fallback and verify release behavior

- Remove automatic model-value requests for arbitrary failed lines.
- Retire the model display-answer path and the network-backed `ask_assistant` workflow.
- Preserve existing source. Flag legacy prompts for explicit conversion to reviewed source.
- Keep user values already saved into source as ordinary values.
- Do not convert cached model replies to accepted expressions automatically.
- Ask existing users to review the new context policy before expanded requests occur.
- Update assistant help, privacy, limitations, settings, release notes, and ADR status.
- Run appropriate engine, editor, table, storage, privacy, and performance checks.
- Exit: no legacy trigger can send a request; the new feature passes all prior gates.

Keep chat, web research, a new symbolic solver, and global function
generation outside this release. A bundled model and live English storage
also need separate plans. Propose one if a repeated user task needs it.

## 11. Work completed for this planning task

Inspected the current assistant, engine, editor, source, table, storage,
privacy tests, and documented performance gates. Used commit `8ef58df` as
the source baseline. Created this plan and the companion proposed ADR.

No implementation code was changed. No Ganit app, AI request, provider
probe, live model evaluation, or assistant test was run. The configured
local model was not contacted. No OpenRouter request was necessary.

Documentation checks validate links, examples, and whitespace. They do not
establish runtime correctness or completion of any implementation phase.

## 12. Related material

- [Proposed decision](../adr/0018-assistant-expression-suggestions.md)
- [Current assistant behavior](../editor/assistant.md)
- [Current assistant decision](../adr/0012-assistant-fallback.md)
- [Evaluation context](../engine/evaluation-context.md)
- [Incremental evaluation](../engine/incremental-evaluation.md)
- [Source and line identity](../engine/sheet-source.md)
- [Current privacy policy](../public/privacy.md)
- [Performance measurement](../public/performance-methodology.md)
- [Microsoft human-AI interaction guidance](https://www.microsoft.com/en-us/research/?p=564561)
- [Inline suggestion interaction reference](https://code.visualstudio.com/docs/editing/ai-powered-suggestions)

The external references support interaction choices. They do not prove
Ganit's proposed harness or timing limits. The current runtime documents
remain authoritative until the implementation and release updates occur.

## 13. Implementation progress

The first code change adds the version 1 response contract, strict JSON
checks, exact value encoding, and an immutable local scope snapshot.
It also adds an injected transport interface. Each transport call sends
one request. The transport has no retry loop.

Tests use synthetic response data and separate test HTTP servers on random
loopback ports. Do not use the user's configured local AI server. Do not
read the user's provider settings or API key in tests.

See [the current API contract](../engine/assistance-contracts.md). The code
is a foundation for the new feature. It is not connected to editor actions.
No phase is complete. The remaining work includes the capability catalog,
evidence and dependency records, candidate checks, semantic choice rules,
the bounded coordinator, editor acceptance, table targets, the automatic
scheduler, removal of the legacy path, and all remaining release gates.

The next code change adds app-owned evidence, native diagnostic spans, a
generated capability catalog, and local candidate checks. Independent tests
cover profit basis, tax base and inclusion, tip and split rules, volume
repairs, nominal monthly rates, scoped references, downstream failures,
clock expressions, and legacy model provenance. The checks passed 650
engine tests and 50 data tests. These tests use no model.

No phase exit gate is complete. Complete dependency and function context,
paragraph and table targets, the request coordinator, source acceptance,
automatic scheduling, legacy removal, and the remaining release gates still
need work.

The request coordinator now has an injected transport and clock, session
permission checks, bounded corrections, context approval, cancellation,
deadlines, request accounting, and a bounded memory cache. Twenty tests
use synthetic replies and a virtual clock. The editor does not use the
coordinator yet. Complete dependency fingerprints, session dismissal,
editor acceptance, and the remaining phase requirements still need work.
No phase exit gate is complete.
