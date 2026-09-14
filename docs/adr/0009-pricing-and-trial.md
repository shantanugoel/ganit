# ADR 0009: Use a one-time purchase and local trial

- Status: Accepted
- Date: 2026-09-14

## Context

Pricing can accidentally introduce accounts, subscriptions, remote authorization, analytics, and separate product editions into core architecture. Those mechanisms conflict with Ganit's local-first promise and are unnecessary to evaluate the product during development.

## Decision

- Development builds and public beta builds are free.
- The initial release uses one transparent one-time purchase with a feature-complete 14-day trial.
- Core calculation never requires an account, subscription, recurring payment, expression upload, or network connection.
- Trial state is local and collects no usage data. Strong anti-tamper behavior is not a product goal.
- The exact price and payment vendor are commercial release details and may not fork the app, engine, document format, or privacy behavior.

## Consequences

- No purchase SDK or licensing dependency enters P0.
- Phase 12 may add a small purchase boundary outside calculation modules after its provider, offline behavior, accessibility, privacy, and failure UX are reviewed.
- A future pricing-model change requires a new ADR; existing documents and calculations remain ordinary local data rather than account assets.
