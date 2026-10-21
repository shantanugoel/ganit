# ADR 0018: Checked AI expression suggestions

- Status: Superseded in part by
  [ADR 0019](0019-ask-one-operation-four-outcomes.md), which amends decision 1
  to permit a marked external fact, defers decision 7, and renames decision 6's
  command. Decisions 2–5, 8–10 stand, and the harness they describe is merged
  into the `ai` branch.
- Date: 2026-10-13
- Implementation: Merged; no phase exit gate is complete
- Companion: [Implementation plan](../plans/ai-expression-suggestions.md)
- Replaces ADR 0012 only when the new workflow is implemented and released

## Context

The current assistant asks a configured model for a value after a line
fails. A display answer and an `ask_assistant` result have different
reference behavior. Neither contract requires a reviewable expression.

The selected product direction is an editor that suggests expressions and
repairs from ordinary English. The user accepts source edits. The normal
engine calculates them. This direction requires more context than the
single-line policy in ADR 0012 permits.

A prompt cannot guarantee correct numerical meaning. Engine checks can
reject invalid arithmetic and some incorrect assumptions. They cannot
prove that arbitrary English has one intended meaning.

## Proposed decision

1. Return source proposals, clarification, context requests, or unsupported
   outcomes. Never use a model-supplied number as the proposed answer.
2. Calculate each proposal locally with the existing engine and a frozen
   source and evaluation snapshot. Use no alternate evaluator.
3. Provide bounded, permission-scoped context. Include exact typed values,
   visible declaration origins, task notes, diagnostics, and grammar facts.
4. Check edit scope, literal evidence, references, units, domains, and
   known material ambiguities. Show remaining interpretations for review.
5. Permit at most three model requests in one job. Count context follow-ups,
   repairs, and response-format fallback within that total.
6. Keep manual suggestions as the default. Require no special source block.
7. Permit optional automatic suggestions only in a visible area enabled
   for the session. Require a completion event, idle time, and request limits.
8. Keep proposals outside accepted calculations. Apply only through an
   explicit user action, with stale checks and one undo transaction.
9. Preserve the accepted expression and original request in ordinary source.
   Do not create a live English calculation representation in this release.
10. Replace the legacy fallback at release. Obtain renewed context consent
    before sending more than the former single-line scope.

## Alternatives considered

| Alternative | Assessment |
| --- | --- |
| Continue model-value fallback | Does not provide reviewable calculations or consistent references. |
| Send the whole sheet on each typing pause | Sends unnecessary context and creates unnecessary requests. |
| Require an AI fence or question prefix | Defines scope, but adds source syntax and interrupts ordinary editing. |
| Require an explicit command for every request | Good default; optional scoped assistance can reduce repeated invocation. |
| Apply corrections automatically | A valid expression can still represent the wrong intention. |
| Build a live English document | A separate product direction with additional meaning and storage rules. |

## Consequences

The engine needs a narrow read-only context and validation adapter.
The editor needs a proposal state separate from accepted results.
Transport and scheduling need finite budgets and injected test providers.
Privacy help must describe permitted context and every follow-up request.

The first implementation uses deterministic fixtures and fake transport.
Live model evaluation is a separate, opt-in release activity with synthetic
data and separate configuration. It is not evidence supplied by this plan.

The current assistant and privacy documents are not changed by this ADR.
They describe the existing runtime until the replacement release occurs.
