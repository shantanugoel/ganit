# ADR 0015: Reference integrity and release announcements

- Status: Accepted
- Date: 2026-09-30

## Decision

Track references across each editor edit using the old source and the actual
replacement range. Existing references to intact expressions follow their
new positions. Newly pasted or explicitly edited references stay as written.
Deleting a target makes its surviving references `@deleted`. Splitting a
nonempty expression or joining nonempty lines makes them `@split`. Blank-line
insertion or removal preserves intact expressions. Each automatic rewrite is
part of the triggering edit's Undo transaction.

Broken markers are additive grammar, evaluated as ranged errors. They persist
in plain source, require no storage schema change, and require an explicit new
reference to repair. Earlier versions reject them as syntax errors rather than
silently computing a different value. Ordinary edits to an intact expression
continue to update its result.

Sheet evaluation carries original failure line numbers through line references,
variables, and aggregates. Multiple known failing dependencies are deduplicated
and reported together. The error card links to those lines. Source syntax and
local evaluation errors remain local causes; failure provenance is regenerated
on each sheet evaluation, including after repairs and line movement.

The feature-specific modal announcement is removed. The bundled Release Notes
window appears once per CFBundleVersion on the first editor open, after any
welcome tour. Background launches defer it until an editor opens. Record the
seen version only after presentation; Help can always reopen it.

The Homebrew cask requests normal application termination with `uninstall quit:`
and prints a reopen reminder. It does not force-kill a running process. The
release workflow renders the cask from `packaging/ganit.rb.in`, preserving this
policy in every published version.
