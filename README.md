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

## Development status

Work proceeds in the ordered phases defined in `PLAN.md`. Each task is reviewed, tested, committed, and pushed before the next task begins. P1 and P2 capabilities are not pulled forward before P0 quality gates pass.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development and testing workflow.

## License

No open-source license has been selected. See [`LICENSE.md`](LICENSE.md) for the current placeholder.
