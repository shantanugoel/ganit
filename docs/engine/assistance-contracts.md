# Assistance contracts

Status: Implementation is in progress. This document describes the current
code changes. It does not establish completion of M0, M1, or M2.

## Module boundaries

`GanitSuggestionProtocol` contains the version 1 response types, size limits,
JSON schema, and strict decoder. It imports Foundation. It has no network,
settings, document, or UI access. The engine and data modules depend on it.

`GanitEngine.AssistanceValue` encodes typed engine values. It preserves exact
integer digits, rational terms, decimal scale, approximation metadata,
units, dimensions, currency codes, and temporal value kinds. A calendar
date has no time zone. An instant retains its time zone.

`SheetCalculator.assistanceSnapshot` captures the native variable, function,
rate, and reference scope before the target declares a name. The returned
snapshot contains the local source, frozen context, and evaluation from
that generation. The normal evaluation cache applies. Snapshot creation
does not read or calculate other sheets.

The current target is one physical source line. Symbol handles identify
records in the captured inventory. The default context contains direct name
matches. An additional handle must come from that inventory. The caller
must get context permission before it includes additional records.

`AssistanceSnapshot.permittedContext` encodes the target, attached comments,
nearest heading, selected symbol records, and evaluation settings. It does
not encode the complete local source or the unselected inventory. It checks
byte and record limits. It does not truncate records. Historical request
comments have an explicit flag. Context keys use a stable order.

The context now contains app-owned literal, temporal, and relation evidence.
It also contains native diagnostics and a generated capability catalog.
The catalog reads native function, operator, keyword, unit, and diagnostic
registries. Its examples have independent expected results in tests.

Selected custom functions now have native source and capture records.
Their complete scalar dependency graph, rate provenance, table records,
and selected paragraph targets still need work.

## Response contract

Each response has `schemaVersion: 1` and one `kind`. The four kinds are:

| Kind | Required data |
| --- | --- |
| `proposal` | One to three candidates |
| `clarify` | One question and up to three choices, or a missing input |
| `need_context` | Named record handles and a reason |
| `unsupported` | A reason |

Each candidate contains an ID, target edits, symbol bindings, literal
records, relation records, assumptions, and a summary. An assumption has
an ID, text, and an evidence handle. It has no model approval field.

The strict decoder rejects unknown fields at each level, extra text,
duplicate JSON keys, invalid JSON syntax, excessive nesting, invalid field
types, and excessive sizes. It checks UTF-8 byte limits and physical line
limits. It does not extract source from prose, Markdown, or reasoning text.

`SuggestionSchema.data` returns the JSON schema for this version. The
`x-maxUtf8Bytes` and `x-maxPhysicalLines` fields describe local checks that
ordinary JSON schema string limits cannot express. The local decoder
applies those checks regardless of provider format support.

## Local candidate checks

`AssistanceCandidateChecker.check` checks one physical line target. It uses
app-owned ranges and the normal engine. It does not apply an edit.

The checks cover target handles, existing labels and names, bindings,
numeric evidence, temporal evidence, declared assumptions, native parsing,
evaluation, result dimensions, and downstream failures. Native scale
suffixes are checked as numeric facts. A suffix cannot hide an extra factor.
The complete shadow sheet stays local.

The local policy checks profit basis, tax inclusion, tax base, nominal rate
period, date order, split exclusions, and mass-to-volume inputs. Profit
basis and changed units can require a user choice. An unstated density
blocks application. The tested tip and tax rules use independent expected
expressions. Other relations remain interpretations for user review.

A checked candidate contains its source change, engine result, affected
results, references, choices, and clock and rate information. It does not
establish that arbitrary English has one correct numerical interpretation.

Native provenance flags follow legacy model values through declarations,
references, imported definitions, units, and function captures. These values
cannot become preview evidence. The context omits their canonical values.

Multi-line edits, complete dependency tracing, table targets, and the full
ambiguity fixture set remain incomplete. This code does not establish the
M1 exit gate.

## Transport contract

`SuggestionTransport.send` is the test injection point. Each call represents
one outbound request. It returns strict response JSON or throws an error.
A coordinator must control repairs, format fallback, deadlines, permission,
and cancellation. `GanitAssistance.SuggestionCoordinator` provides these controls.

`SuggestionWireRequest` freezes its body, endpoint, and timeout. The context
inspector can read the same body that transmission will use. The key is an
Authorization header. It is not part of the body. Body limits apply after
JSON encoding, including escapes and instructions.

`ProviderSuggestionTransport` uses an ephemeral session. It refuses all
redirects and bounds the received payload while it reads bytes. Each call
creates and closes one session. It accepts one completion content string.
It rejects reasoning-only replies and content-part arrays. It makes no
format fallback or transport retry. A local endpoint has a 120-second
request timeout. A remote endpoint has a 30-second request timeout.

## Verification

The tests use fixed engine contexts, synthetic replies, and separate test
HTTP servers. They do not use the configured local AI server or read user
provider settings or keys. The tests cover scope capture, redeclarations,
dividers, frozen values, source privacy, exact value encoding, strict
response checks, body privacy, request count, redirect refusal, and limits.

The editor has an explicit source review and acceptance path for one physical
line. Paragraph and table targets, automatic scheduling, complete dependency
records, model evaluation, and user sessions remain part of the full
[implementation plan](../plans/ai-expression-suggestions.md).

The foundation check passed on 2026-10-13 with Xcode 27.0:

```sh
swift test --filter 'GanitEngineTests|GanitDataTests' -Xswiftc -warnings-as-errors
./scripts/swift-format.sh lint
git diff --check
```

The test run passed 624 engine tests and 50 data tests. These results apply
to the foundation APIs. They do not establish completion of the editor or
release gates.

The next local check passed 650 engine tests and 50 data tests with the same
commands. It covers the generated catalog, evidence checks, independent
profit and tax choices, tip and split constraints, native references,
downstream failures, and legacy model provenance. No model was contacted.

Literal checks retain quantity units and currency codes. A mass cannot
supply a price. A converted literal cannot replace the supplied input;
retain the conversion expression. Tests cover these failures and valid
quantity and currency literals.

A proposal cannot hide a native input error by dropping an operand.
`userRevisedInputs` is an application control for a user-supplied input or
constraint revision. It is false by default. A model response cannot set it.
The input revision workflow is not connected to the editor yet.

## Request coordinator

Share one `SuggestionCoordinator` across application windows. Its input
contains the frozen snapshot, provider settings, and session permission.
The coordinator does not read saved provider settings or keys. Each job
permits at most three wire requests, including context requests, corrections,
and the single response-format fallback. A transport failure stops the job.
A repeated source or failure stops correction. No timer starts another job.

A remote job has a 90-second deadline. A local job has a 180-second deadline.
Each wire request also retains its transport timeout. An injected clock
controls both deadlines in tests. Cancellation and source invalidation
prevent a late response from becoming a preview.

A provider can have one active job and one pending automatic target across
windows. A manual request has priority over an automatic request. Automatic
requests require a session area. They have a 15-second minimum interval,
two jobs and six wire requests per minute, and twelve jobs per area.
These controls do not implement the editor completion-event scheduler.

Additional context waits for an explicit application action. The exact
encoded wire body is available to the context inspector. Every follow-up
uses the same permitted-context encoder. Feedback contains stable error
codes and native spans. It does not contain the complete shadow source.

The memory cache has limits of 128 entries and 4 MiB. Cached proposals must
pass the local checker again. No transport failure is stored as an answer.
The cache still needs complete dependency and rate fingerprints. Editor
session state must also retain dismissed outcomes before automatic mode
can use this coordinator.

The coordinator passed twenty tests with synthetic replies and a virtual
clock. These tests cover request counts, context permission, exact request
bodies, deadlines, late replies, window priority, automatic limits, and
cache eviction. They do not establish the M2 or release exit gate.

## Explicit editor review

`SheetSuggestionConfiguration` supplies the coordinator and provider settings.
Workspace sheets and Quick Ganit share the application coordinator. Provider
setup does not grant context permission. Suggest Expression prepares a scope.
Send is a separate action. The settings example also prepares a scope before
it can send a request. Tests inject synthetic replies and separate settings.

The temporary card contains the source edit, local result, interpretation,
references, choices, and assumption approval. Context shows the exact request
body. A clarification adds an explicit task note to a new request. The user
must review and send that request separately. A card cannot supply a normal
answer, total, export result, or Copy Result value.

Apply takes a fresh native snapshot and checks the complete source change.
`AssistanceSourceEdit` contains the checked edit and its local evaluation.
The accepted expression stays on the original physical line. Historical
request comments follow that line. Approved task notes and assumptions also
remain in source. Existing references retain the expression's identity;
references to later lines move through the native reference transformation.
The editor applies the patches through `SheetSourceCoordinator` in one Undo
transaction. Undo and Redo restore the source and selection together.

Tab accepts only when Use Expression has focus. Return edits the sheet.
Escape dismisses the card before it dismisses Quick Ganit. Source edits,
provider changes, and native namespace changes make the preview stale.
Closing its window or hiding Quick Ganit cancels the suggestion. If a fresh
local result differs, Apply first updates the preview for another review.

The current selection must be one complete physical line. A partial line
or a multi-line selection shows a scope error. These targets still need
implementation; this restriction does not complete or reduce the plan.
The current card is in the editor review area. Placement beside the target,
full accessibility review, real IMEs, visual checks, and release measurements
still need work. No phase exit gate is complete.

The application no longer attaches the legacy model-answer callbacks or
opens their answer store. Legacy engine and editor APIs still need removal.
The new feature does not load cached model values into accepted source.

## Native function context

The engine retains a source identity with function declarations and their
captured variables. Source identity includes an internal document identity
and a physical line identity. Equal line numbers in two sources cannot
identify the same declaration. The records come from the normal engine
fold. The adapter does not open or calculate the definitions sheet.

A selected function record contains its source, parameters, exact captured
values, captured declaration origins, called function versions, and compiled
unit transforms. Parameter names and comment words do not create captures.
The context is a flat list. It has no recursive JSON structure. Required
records count against the context limit. An excessive closure is rejected;
its records are not cut off.

The checker requires an explicit function binding. An unreviewed model
capture cannot supply a value or a preview. A failed captured input cannot
be hidden by dropping the function. Native local origins also supply the
reference-focus targets in the card. A function imported from another
source cannot point to an unrelated local line with the same line number.

Tests cover redeclarations, nested calls, imported captures, parameter and
comment scope, exact rational values, custom units, record limits, source
identity, and failed or legacy captures. Coordinator tests also cover
changed captures and explicit material choices in request and reuse keys.
Complete scalar and table dependency records and all earlier incomplete
requirements still need work. No phase exit gate is complete.

The function-context check passed 665 engine tests, 22 coordinator tests,
226 editor tests, 15 Quick Ganit tests, and 60 workspace tests on 2026-10-13.
All 988 tests used local calculation or separate test transports. No test
contacted the configured AI server. Format and whitespace checks also passed.
