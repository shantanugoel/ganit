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

Function capture records, complete dependency records, table records, and
selected paragraph targets still need work. A custom function cannot pass
checking until its required definition is in the permitted context.

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
and cancellation. That coordinator is not yet implemented.

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

No editor action uses these APIs yet. Source acceptance, reference changes,
Undo, table validation, scheduling, model evaluation, and user sessions
remain part of the full [implementation plan](../plans/ai-expression-suggestions.md).

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
