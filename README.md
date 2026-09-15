# Ganit

Ganit is a native, local-first macOS thinking calculator. It is designed to combine an immediate global-hotkey scratchpad with durable, editable calculation sheets backed by one deterministic engine.

The project has a runnable native skeleton but is not yet a usable calculator. [`PLAN.md`](PLAN.md) is the normative product and implementation plan.

## Product principles

- Correct before clever: invalid or ambiguous input must never appear valid.
- Exact by default: integer, rational, decimal, money, and unit calculations remain exact whenever their semantics permit.
- Native Mac behavior: AppKit text editing, windows, menus, accessibility, restoration, and system conventions are core requirements.
- Local and private: core calculation needs no account, telemetry, permission, or network access.
- Durable text: source text is authoritative, recoverable, and independent of derived indexes or answer caches.
- Measured efficiency: launch, typing, memory, energy, and storage budgets are release gates.

## Planned structure

The application is AppKit-first and targets macOS 14 or later. Pure Swift packages keep calculation, formatting, documents, data, diagnostics, and system integrations separate from UI modules. The engine receives all locale, clock, calendar, time-zone, and live-data context explicitly.

Accepted architectural choices are indexed in [`docs/adr`](docs/adr/README.md).

## Documentation

- [Grammar reference](docs/public/grammar-reference.md)
- [Privacy](docs/public/privacy.md)
- [Data sources and attribution](docs/public/data-sources.md)
- [Correctness corpus highlights](docs/public/corpus-highlights.md)
- [Performance methodology](docs/public/performance-methodology.md)
- [Known limitations](docs/reference/known-limitations.md)
- [Recovering your sheets](docs/storage/recovery-guide.md)

## Development status

Phases 0–10 are implemented, and Phase 11 hardening is under way; [`PLAN.md`](PLAN.md) records what remains, including the usability sessions, beta, competitor comparisons, and notarized release that need people or credentials. Each task is reviewed, tested, committed, and pushed before the next task begins.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development and testing workflow.

## License

No open-source license has been selected. See [`LICENSE.md`](LICENSE.md) for the current placeholder.
