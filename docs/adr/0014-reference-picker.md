# ADR 0014: Quick references with @

- Status: Accepted (announcement and edit policy superseded by ADR 0015)
- Date: 2026-09-30

## Context

Repeated `line N` references are verbose. Variables need discoverable completion
without making ordinary calculations less readable. The user approved a shared
`@` picker, compact references, a one-time announcement, and visible line numbers.

## Decision

- `@N` is an alias of `line N` in the existing parser and evaluator, with the
  same physical line numbering, upward-only resolution, and errors. The decimal
  integer must touch `@`.
- `@` opens an editor picker of variables currently in scope and earlier line
  results. A choice replaces the query with a plain variable name or `@N`.
  `@name` is completion input, not persisted variable-reference syntax.
- Completion previews read evaluated values; UI code does not evaluate source.
  Shared definitions survive dividers, local variables follow declaration order,
  and failed or unavailable values are omitted.
- Automatic suggestions include variable names. An explicit `@` query works
  with automatic suggestions off. Escape dismisses it, Tab/click accepts it,
  and Return accepts the explicit picker. Ordinary suggestions retain their
  existing Return behavior.
- Both line-reference spellings renumber within the triggering undoable edit.
- New sheets and settings missing the line-number key show the gutter. A saved
  choice remains authoritative. A feature-specific local preference records
  that the small announcement has appeared; later versions do not repeat it.

## Consequences

Existing expressions and headings keep their meanings. `@` does not compete
with headings (`#`), factorial (`!`), labels, or time colons. Plain text remains
the authoritative source and the storage schema stays unchanged.
