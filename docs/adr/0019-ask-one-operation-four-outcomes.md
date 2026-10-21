# ADR 0019: Ask — one operation, four outcomes, and the facts a model may name

- Status: Accepted
- Date: 2026-10-21
- Amends: [ADR 0018](0018-assistant-expression-suggestions.md) (decision 1, and
  the naming of decision 6) and withdraws the automatic-request half of
  [ADR 0012](0012-assistant-fallback.md)
- Plan: [AI as part of the calculator](../plans/ai-native.md)
- Contract: [the frozen Ask job contract](../design/ai-native/ask-job-contract.md)

## Context

ADR 0012 sends a line a person cannot get Ganit to read to a model and prints
the model's number in purple. ADR 0018 sends selected source to a model and
lets a person accept the source back. Both are in the tree. That is two AI
mental models in one calculator, and ADR 0012's own consequence line — "a
request nobody makes without asking for it" — is the thing the design
walkthrough objects to most.

The plan settled the experience: one operation, **Ask** (⌘⇧A), whose outcome
shape decides what the reader has to do. Three things in it could not be
adopted from ADR 0018 as written, and each needs a sentence somewhere other
than the plan, because each constrains code the engine and the coordinator
will enforce:

1. ADR 0018 decision 1 forbids a model supplying a number, full stop. The
   plan's flagship example — `10 kg of water in ml` — cannot be done without
   one: water's density is not arithmetic, and Ganit has no density.
2. ADR 0018 decision 7 permits automatic suggestions in an enabled area. The
   plan defers them, because the passive `Ask` chip is what makes an
   unrequested request unnecessary.
3. ADR 0018 decision 6 names the command **Suggest Expression**, which makes
   the reader classify their intent before the tool knows it.

## Decision

### One operation, four outcomes

Ask is one command with one bar. The reader can meet four things, and the shape
decides what is asked of them:

| Outcome | Reader does | Survives on screen |
| --- | --- | --- |
| 1 · Explanation card | nothing; Esc closes | no |
| 2 · Answer card | nothing; Esc closes | no |
| 3 · Proposal | **Apply** ⌘↩, line by line | becomes ordinary source |
| 4 · Question | one answer, in the same bar | no |

Two more yields sit outside that count, which is why the plan's §5 lists six.
An **assumption value** is the durable form a proposal takes: a `proposal`
whose candidates carry `requiresAssumptionApproval`, which the harness already
has and which makes `isApplicable` false until the reader approves. And a
**failure** is the absence of an outcome rather than a kind of one — four reason
classes, all in Ganit's words.

There is no chat surface, no mode switch, no AI panel, and no AI state that
outlives the job. Read-only outcomes cannot be referenced and are not saved.
A proposal that does not parse and calculate is a failure, never a dimmed
preview. Only two of the six leave anything behind: a proposal becomes ordinary
source, and an assumption value stays as a marked line.

### The carve-out: a model may name a fact, never do arithmetic

ADR 0018 decision 1 stands in full for **arithmetic** and for **user intent**,
and is carved out for one thing. A model may name a fact about the world,
which must then become a declared value that Ganit calculates with:

- The fact is world knowledge, not intent. A tax rate, a currency of a salary,
  or a budget figure is intent, and intent is asked about. A physical constant,
  a typical rate, or a material property may be assumed. **When that
  classification is uncertain, ask.** The bar's rule of thumb is in Help:
  *Ganit asks when only you know; it assumes and marks when the world knows.*
- It materialises as a declared, named, plain-text value on its own line.
  Never a literal inside an expression, never a displayed answer. This keeps
  ADR 0018's rule where it matters: the engine calculates every preview and
  every accepted result, from frozen source, with no alternate evaluator.
- It carries a provenance comment Ganit writes and the reader can delete,
  `// AI: density of water at 4 °C · <model> · <date>`, following the existing
  `// Manual answer; original:` precedent. The badge is that comment rendered,
  not a parallel record.
- Lines that transitively read it get a mark derived from the engine's
  dependency graph. `View ▸ Mark AI-derived answers` (M3) hides the marks; the
  origin badge never hides. Editing the value removes both, because a number
  the reader typed is the reader's.
- AI-written *structure* that Ganit verified is unmarked. A permanent "AI wrote
  this" badge on a checked formula would say *distrust this line* about the one
  thing that is not a guess.

`AssistanceCandidateChecker` today refuses a literal it cannot ground in
supplied evidence (`missingEvidence`). It gains one permitted source for such a
literal: a candidate assumption carrying a basis, which lands as a declared
value line. That is the whole of the amendment, and it is the only substantive
product disagreement between the two plans.

The harness does not yet behave this way, and M3 has to change it. Its
`AssistanceSemanticPolicy` answers a mass-to-volume conversion with no density —
this design's own flagship example — by emitting a required choice
`missing_density` (*"What density should this conversion use?"*) with **no
options at all**, and a candidate carrying a required choice is not applicable,
so Apply is unreachable and the answer cannot be picked from a list. The policy
rule is replaced by an assumption with a basis, not by a question, and M3's gate
asserts `missing_density` no longer appears.

### Detect locally, send on request

ADR 0012's automatic 1.2-second request is withdrawn. Ganit detects a line it
cannot read on device and offers a quiet `Ask` chip beside the diagnostic it
already shows. Nothing leaves the Mac until ⏎ in the Ask bar. The automatic
path ADR 0018 decision 7 allowed stays unimplemented: the coordinator's
`.automatic` origin has no caller. It comes back only by reopening decision 7,
and only on the evidence plan §11 already names — request-only usage showing the
need. Ganit collects no telemetry, so that evidence is a person using it and
saying so, not a metric.

### Context is minimal, and it is shown

The `Context ▸` disclosure in the bar is what
`AssistanceSnapshot.permittedContext(including:)` returns, rendered for a
person: the target text, its attached non-historical notes, the symbol records
whose names the target mentions or whose parse it directly reads (one hop, not
the whole transitive closure), the settings record — locale, precision, the
rounding mode and the evaluation clock — the function catalog, and the
diagnostic and evidence records. The model name and the `Effort` word are not in
the snapshot; the transport adds them, and the disclosure lists them too.

A sheet-level Ask sends the sheet as far as the harness's own target limits
allow — 12 lines, 8 KiB, contiguous, and never overlapping a table block. A
sheet wider than that is asked about line by line, not silently truncated.
The disclosure is openable before the request goes, and what it lists is what
goes.

Transport protections from ADR 0012 are unchanged: HTTPS except loopback,
redirects refused, ephemeral session, key in the keychain, `User-Agent:
Ganit`. `SuggestionWireRequest` builds `model`, `stream`, `messages` and
`response_format` today; M1 adds `reasoning_effort` to it, as M-1 did for the
legacy request, and `NetworkPrivacyTests` names every key in both bodies.

### The answer column is Ganit-only

AI output lives in cards or in source. The purple display answer,
`AnswerCell.isAssisted`, and the reference errors that warned a formula had
reached an AI value go away with M5. This retires a two-tier answer concept
that made `line N` and `previous` behave differently depending on who produced
a number.

### Reuse, not a second harness

The harness from `codex/ai-expression-plan` is merged into this branch and is
the only snapshot adapter, candidate checker, budget counter, and proposal
state machine in the product:

| Layer | What is reused |
| --- | --- |
| `GanitEngine/Assistance*` | frozen snapshot, `permittedContext`, candidate checker, shadow evaluation, evidence and value encodings, catalog, semantic policy |
| `GanitSuggestionProtocol` | strict decoder, size limits, JSON schema |
| `GanitAssistance` | coordinator with budgets, in-memory cache, deadlines, request accounting |
| `GanitData/Suggestion*` | bounded transport with a scheme rule (HTTPS; HTTP only on loopback) |
| `SheetSourceCoordinator` | Apply as one named Undo step |

Six written divergences, each in the contract document:

1. **Addressing.** A model addresses lines by the snapshot's opaque handles and
   the editor addresses a proposal by `LineID`. That is the intent, not today:
   an `R` handle is `R<lineID.rawValue>`, and a symbol's declaration is encoded
   as `line:<rawValue>`, so the merged snapshot puts a line's ordinal on the
   wire. M1 re-keys both.
2. **One edit, always the target.** The checker accepts exactly one edit whose
   target is `T1`; anything else is `unauthorizedEdit`. Multi-line proposals
   arrive as replacement text for that one target, with derived lines bound as
   `L1`, `L2`, …, and a proposal that needs more is a divergence, not a
   workaround.
3. **Outcomes.** The wire contract's `need_context` becomes the `Context ▸`
   disclosure's opt-in rather than a separate outcome, and `answer` and
   `explanation` are added, both read-only and never referenced.
4. **Naming.** One command, **Ask Ganit…** at ⌘⇧A, replacing **Suggest
   Expression** at ⌘⇧I; the Undo step is **Apply AI change**.
5. **Assumptions.** The checker's literal-evidence rule gains the carve-out
   above, and `AssistanceSemanticPolicy`'s option-less `missing_density` choice
   is replaced by an assumption with a basis.
6. **Sheet-level asks.** The harness target limits govern what a sheet-level
   Ask can send; the plan's "send the sheet" means the sheet within them.

## Alternatives considered

| Alternative | Rejected because |
| --- | --- |
| Keep ADR 0018 unchanged: no model-supplied fact, ask instead | the flagship example cannot be answered; a question with no options is not a question |
| Keep ADR 0012's automatic fallback and add Ask beside it | two AI mental models in one calculator, and the passive request is the part the walkthrough objects to |
| Let a model supply the answer value and mark it purple | the answer column becomes a second tier of truth, which is the thing M5 removes |
| Mark every AI-written line permanently | a permanent distrust badge on a formula Ganit verified says the wrong thing about the one thing that is not a guess |
| Build the Ask layer fresh rather than adopt the harness | a second snapshot adapter, checker and budget counter, which the working agreement forbids outright |

## Consequences

- A sheet can contain a number that came from neither its author nor Ganit's
  arithmetic. It is findable by grep, marked on screen, and removable by
  editing it. ADR 0012 achieved the same end by colour alone, which told the
  reader nothing they could act on.
- The privacy statement has to say that a request carries the lines a context
  disclosure listed, which is more than "one line and nothing else", and the
  disclosure is what makes the bigger ask inspectable instead of implicit.
- Two AI surfaces exist while M1–M4 build. M5 removes the ADR 0012 one, as its
  §7 table schedules, and ADR 0012 becomes history at that point rather than
  now.
- Anything that later wants automatic suggestions is reopening decision 7 and
  owes the usage evidence plan §11 named for it.
