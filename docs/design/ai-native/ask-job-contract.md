# The Ask job contract

Status: **frozen at M0** by [ADR 0019](../../adr/0019-ask-one-operation-four-outcomes.md).
Changing a name, a field, or an outcome here is a design change, not an
implementation detail.

This is the shape an Ask job has, in the code that already exists from
`codex/ai-expression-plan` and the places the Ask design changes it. The
engine-side contracts — snapshot, permitted context, candidate checks, value
encodings — are specified in
[assistance contracts](../../engine/assistance-contracts.md) and are not
restated here.

## Contract and implementation

The Ask implementation uses the existing harness. The table records the
M0 baseline and the work in M1 through M5.

| M0 baseline | Work in M1 through M5 |
| --- | --- |
| `SuggestionJobInput`, `SuggestionJob`, `SuggestionJobState`, `SuggestionJobEvent`, `SuggestionCoordinator`, `SuggestionClock`, `SuggestionLimits` | — |
| `SuggestionJobResult` with `proposal`, `clarify`, `unsupported`, `failed`, `cancelled`, `dismissed`, `stale`, `paused` | `AskJobOutcome` with `explanation`, `answer`, `proposal`, `clarification`, `failure`, and `AskFailure`'s four reason classes |
| `AssistanceSnapshot`, `permittedContext`, and the `T1`/`S<n>`/`R<n>`/`F<n>`/`N<n>`/`E<n>`/`L<n>` handles | the `Context ▸` disclosure that renders them; re-keyed `R<n>` handles and `line:<rawValue>` origins |
| `SuggestionWireRequest` sending `model`, `stream`, `messages`, `response_format` | `reasoning_effort` on that body, as M-1 did for the legacy request |
| `AssistanceCandidateChecker.check`, `prepareSourceEdit`, `AssistanceCheckedCandidate`, `AssistanceValidationFailure` | the one permitted ungrounded literal, for an assumption |
| `AssistanceSourceEdit` with `sourceBefore`, `patches`, `referenceMapping` | the Apply button, naming its step **Apply AI change** |
| `SuggestionJobOrigin.automatic` and its rate limits | nothing — they stay unreachable in v1 |
| `AssistanceSemanticPolicy`'s option-less `missing_density` required choice | its replacement by an assumption with a basis, so the water example reaches Apply (M3's gate) |

`Effort` was added at M-1. **Repair attempts** was added at M2.
**Mark AI-derived answers** was added at M3.

## One job

An Ask job is one call to `SuggestionCoordinator.start(_:observer:)` with one
`SuggestionJobInput`. It is started by the Ask bar and by nothing else.

| Input | Where it comes from |
| --- | --- |
| `snapshot` | `SheetCalculator.assistanceSnapshot(_:context:target:)` or the `targets:` overload, taken at the caret line, the selection, or the whole sheet **within the harness target limits: 12 lines, 8 KiB, contiguous, no table-block overlap** |
| `settings` | `AssistantSettings`, `effort` included |
| `document` | The saved sheet identity. Source and settings changes invalidate its jobs and cache. |
| `permission.contextAccepted` | False until the reader sends. The Ask bar makes `Context ▸` available before Send. An explicit send action is Return, Ask, Answer, Retry, or a clarification choice. Opening Ask or the disclosure sends nothing. |
| `includedRecords` | extra symbol handles the reader opted into |
| `choices` | answers to earlier clarifications in this job, `AssistanceChoice.id → Option.id` |
| `retry` | **Try again** on a failure card |
| `origin` | `.manual`, always, in v1 |

A job yields exactly one `SuggestionJobResult`. It does not accumulate a
thread: a second Ask is a second job, and the first is gone. A clarification
answer starts a new job too — a fresh snapshot, a fresh body, `choices`
filled in — because the harness returns from `clarify` and ends the job; what
the reader sees is one continuous exchange in one bar.

## Four outcomes, six yields

The user can see four result shapes. Section 5 of the plan lists six
job results. The wire format also permits a request for more context. An assumption value is a `proposal` whose candidates carry
`requiresAssumptionApproval`, which the harness already has and which makes
`isApplicable` false until the reader approves, and the bar renders that case as
the assumption card. A failure is the absence of an outcome. `proposal` and
`clarify` keep their harness meanings; `unsupported` is folded into `failed`; two
read-only cases are added.

```swift
public enum AskJobOutcome: Sendable {
  case explanation(AskExplanation)        // card; Esc closes; never referenced
  case answer(AskAnswer)                  // one unverified value; never referenced
  case proposal([AssistanceCheckedCandidate])   // Apply, per line
  case clarification(SuggestionClarification)   // the bar becomes the question
  case failure(AskFailure)                // a reason in Ganit's words
}
```

`cancelled`, `dismissed`, `stale`, and `paused` remain job states.
The Ask bar shows their status. It does not make a result card for them.

**Explanation.** Engine-sourced: expression, result, dependencies, the applied
grammar rule, assumptions, diagnostics, all from `SheetEvaluation` and the
existing interpretation card. `sent: false` says so, and the card states it.
The model is the fallback for intent-level questions, and then the card is
model-sourced and says that instead.

M4 uses `SuggestionJobResult.explanation(String)` for the model fallback.
`SuggestionJobInput.allowsExplanation` defaults to false. The request schema
permits `kind: explanation` with one bounded `text` field only when this flag
is true. The decoder rejects numeric characters and equation operators in
that text. The coordinator also requires a manual request and context
permission. Explanation replies are not cached. They do not enter the
candidate checker or change source. The card identifies the model and states
that context was sent and that Ganit did not verify the explanation.

The local route reads the current `SheetEvaluation`. It does not create a
provider job. If evaluation is not current, it asks the reader to wait.
**Fix it** prepares an ordinary proposal request with diagnostic context.
**Ask the model instead** prepares an explanation request. Both actions
wait for Send and keep Context available.

**Answer.** M5 adds `SuggestionJobResult.answer(String)`. The card shows one
text answer and marks it as unverified. It states that context was sent.
It has no Apply action. It cannot supply a line result or a symbol. It is
not saved or cached. Esc closes it.

This result must comply with rule 1 of the plan. It cannot contain a model
number. The decoder rejects Unicode numeric characters, common English number
words, and equation operators. The coordinator permits it only for a manual Ask that has context
permission and `allowsAnswer`. An explicit Explain request cannot return an
Answer. Numeric evidence, a matched or included source symbol, or a current
target value blocks this result. A calculation must use a checked proposal.
A world fact needed by a calculation must use a named assumption.

The exact request body includes the Answer schema only when these local
checks pass. The prepared disclosure and the sent body use the same check.
Late replies from a stale job are discarded.

**Proposal.** `[AssistanceCheckedCandidate]`, each already shadow-evaluated on
the frozen snapshot. An unparseable or non-calculating candidate never reaches
the proposal view — `AssistanceValidationFailure` sends it back for a repair
turn instead, and an exhausted budget is a `failure`, not a dimmed preview.

**Clarification.** One `SuggestionClarification` at a time, at most two per Ask
across its jobs. There is no counter in the harness; M3 owns it. The bar becomes
the question, the original instruction stays visible as a crumb, and the answer
starts the next job with `choices` filled in. A third question is a
`failure(.noUsefulAnswer)`.

**Failure.** Four reason classes, each with its own sentence and none of them
technical:

| Class | The reader reads |
| --- | --- |
| `.notGanitSource` | Ganit could not turn the reply into Ganit source |
| `.rejectedByEngine(AssistanceValidationFailure)` | Ganit's own diagnostic, in Ganit's words, plus the names it would have used instead || `.unreachable` | Ganit couldn't reach *host* |
| `.noUsefulAnswer` | The model didn't answer in a way Ganit could use |

`.rejectedByEngine` carries the `AssistanceValidationFailure` that was fed back
for the repair turn — `code`, `message`, `ranges`, and the engine result. The
card's suggestions are not in that payload: Ganit derives them from the
`AssistanceCatalog` already in the context, so an invented `mortgage` is met
with `pmt`, `fv` and `pv`.

## Addressing: handles on the wire, LineID in the sheet

A model should never see a `LineID`, and the editor never trusts a model's idea
of a line number. The second half is true today; the first is M1's to make true.

- The prompt carries the snapshot's opaque handles: `T1` for the target, `S<n>`
  for symbols, `R<n>` for line results, `F<n>` for functions, `N<n>` for notes
  and `E<n>` for evidence, and `L<n>` for the derived lines a proposal binds.
  The system prompt tells the model to bind derived names to `L1`, `L2`, …
- `R<n>` is `R<lineID.rawValue>` today, and a symbol's declaration is encoded as
  `line:<rawValue>`, so a line's ordinal is on the wire. M1 re-keys both.
- A candidate carries **exactly one** edit, whose target is `T1`; the checker
  throws `unauthorizedEdit` for a second edit or any other handle. Multi-line
  proposals are replacement text for that target, with derived lines bound as
  `L<n>`.
- `AssistanceCheckedCandidate` resolves to `LineID`s locally: `resultLineID`
  for the produced value, `changedResults` for what moved, and
  `referenceMapping` for an existing `line N` reference whose target became
  ambiguous, mapped to the final line that must serve it — which is what
  `LineReferenceRenumbering` applies so `line N` references follow the
  intention they were written against rather than the text.
- A proposal's per-line opt-out, Apply, and stale checks all work on `LineID`s
  against the *current* `SheetSource`, never against a byte offset a model
  proposed.
- `sourceBefore` on `AssistanceSourceEdit` is the fingerprint. Apply compares
  bytes, target membership, and the re-check on a fresh snapshot; a mismatch is
  `SheetSourceCoordinator.Failure.staleEdit` and the proposal view says the
  sheet changed under it.

M1 uses one control for each replacement, insertion, or deletion. If the
reader declines a replacement or deletion, Ganit keeps the original line.
If the reader declines an insertion, Ganit removes that proposed line.
Ganit updates local bindings and checks the complete revised source again.
A failed check removes the preview and prevents Apply. It sends no request.
The preview shows each result from the engine. Apply uses the same revised
candidate on a fresh snapshot.

The context uses opaque `source:N` keys for declaration origins. It includes
`dependencySources` records for the local source lines that the selected
records read. Ganit uses each line's native scope to find these records.
Thus, a later declaration does not replace an earlier captured input.
The disclosure includes function definitions, captured inputs, dependency
source, and the exact request body. The existing size limits apply to all
these records. Ganit does not open another sheet to build context.

## Apply

`AssistanceCandidateChecker.prepareSourceEdit` on a fresh snapshot immediately
before applying, then one call:

```swift
try sourceCoordinator.apply(edit.patches, actionName: "Apply AI change")
```

One named Undo step, through the coordinator tables already use, restoring
bytes and selection. No AI-specific undo stack, no second document source, and
table blocks go through `TableSourceCoordinator` the same way.
## Budgets

The harness's numbers are the ceiling, and they are shared: one initial
request, a response-format fallback, a context follow-up and each repair all
count against `requestsPerJob`.

| Budget | Value |
| --- | --- |
| Wire requests per job | `SuggestionLimits.requestsPerJob` = 3 |
| Repairs within that | Settings' **Repair attempts** (M2) clamps to `requestsPerJob − 1`, so 0–2, default 2; a budget of 2 leaves no room for a format fallback, and the coordinator's accounting decides which is dropped. Raising `requestsPerJob` is a contract change |
| Target | 12 lines, 8 KiB, contiguous, no table-block overlap |
| Context | 24 KiB |
| Request | 64 KiB |
| Payload | 256 KiB |
| Candidates | 3 |
| Replacement | 16 lines, 4 KiB |
| Clarifications per Ask | 2, counted across jobs by M3 |
| Cache | in-memory only, ≤128 entries / 4 MiB and 4 MiB per entry, keyed by document, source, context digest, provider and model; `AssistantAnswers.json` is retired with the legacy path |

The repair turns are invisible except for one status line the second turn adds
— *Ganit asked the model to fix its first attempt.* — and one footer clause
once a proposal appears — *Ganit checked these lines · 1 automatic repair*.

M2 retains the native diagnostic and its source ranges in repair feedback.
Unknown function feedback includes function names from the supplied catalog.
Schema corrections count as repairs. A format fallback or context follow-up
uses the shared request budget but does not increase the repair count.
With Repair attempts set to zero, a rejected reply stops after its first
check. A setting of three still permits at most two repairs because the
shared request limit is three.

The coordinator emits a classified failure before the terminal state.
The editor removes all proposal controls on failure. A separate action can
show rejected source or a malformed reply as read-only text. The text is
explicitly marked as rejected. It is not a preview and has no Apply action.
The editor limits this view to 16,384 characters and identifies shortened
text. Retry starts a new explicit job. It does not bypass the size limits
or the engine checks.

The real transport keeps strict reply validation. If a text reply fails that
validation, a bounded transport error retains its bytes. The coordinator
uses these bytes only for the rejected-reply view and repair accounting.
Reasoning fields and content-part arrays cannot supply this text.

## The classification rule

The one decision the model is not trusted with, stated once:

> **If the world knows the number, Ganit assumes it and marks it. If only you
> know it, Ganit asks. If it is uncertain which, Ganit asks.**

| The missing number is | Ask does | Where it lands |
| --- | --- | --- |
| a physical constant, a typical rate, a material property | assumes it | a declared value line with a `// AI:` comment, a badge, and dots downstream |
| a tax rate, a salary's currency, a budget, a plan | asks, once | the reader's own typed value, unmarked |
| a number the reader's own words imply ("around 8%") | proposes it, marked `said` | an ordinary value line; the mark is decoration |
| something the reader never mentioned | proposes `0  // not given — set me` | a visible hole, not an invention |
| any of the above, and the classification is doubtful | asks | — |

An assumption is a `SuggestionAssumption` with an `id`, human-readable `text`
stating its basis, and an evidence handle. The checker's literal-evidence rule
gains exactly one permitted source for a literal it cannot ground: such an
assumption, which must arrive as a declared value line. `approvedAssumptions`
carries the reader's approval through a repair turn. Editing the value in the
sheet removes the comment, the badge, and every downstream dot, and afterwards
the line is indistinguishable from one that was typed.
