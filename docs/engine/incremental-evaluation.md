# Incremental evaluation

`SheetCalculator` owns the per-line cache for one sheet and evaluates each new
`SheetSource` snapshot as a generation.

## What a line depends on

Sheet semantics are a top-to-bottom fold: each line reads only state produced
above it. A line's result is therefore a function of:

- its text, which determines its role, declared name, and expression;
- the evaluation context;
- the visible variables whose names can be formed from consecutive identifier
  words in the line, including their values (and so their kinds, which guide
  parsing);
- for each `line N`, `previous`, or aggregate reference in its expression, the
  exact outcomes that reference reads.

The cache is keyed by `LineID` and stores the text-derived parts plus the last
result and the variable values and reference inputs it read. In each
generation, the calculator walks the lines, rebuilds scope and block outcomes,
and recomputes only these inputs. A line is parsed and evaluated again only
when its text changed or an input differs; otherwise its result is reused.
Walking is linear in the number of lines, but unaffected lines are never
relexed, reparsed, or re-evaluated.

Parsing depends only on the text and the kinds of the names a line can use.
When a dependency's value changes but those kinds do not, the line reuses its
cached AST and is only re-evaluated. Each line passes the parser and evaluator
just the variables its words can name, never the whole scope.

Because a result depends only on its inputs, invalidation is transitive by
construction: if a changed result alters what a later line reads, that later
line re-evaluates, and so on down the sheet. Lines whose inputs are unchanged
stop the propagation even when a line above them was re-evaluated.

Changing the evaluation context clears the cache. Cache entries for removed
lines are dropped at the end of a completed generation.

`SheetEvaluation.evaluatedLineIDs` lists the lines evaluated in a generation,
and `parsedLineIDs` the subset that was also parsed, so tests can assert that an
edit touched only its dependents. Cached entries are immutable, so reusing a
line and returning its result share storage rather than copying values.

## Generations and cancellation

Every call to `evaluate(_:context:)` starts a new generation and returns a
`SheetEvaluation` carrying its generation number. One generation uses one
immutable context and sheet snapshot.

Cancellation is cooperative through Swift task cancellation. The calculator
checks between lines and throws `CancellationError` instead of returning a
partial evaluation. Results computed before cancellation stay cached, because
each is valid for the inputs it recorded. A caller commits an evaluation to the
UI only when its generation is the newest one it started, so stale generations
never replace newer answers.

## Clock boundaries

A line whose evaluation read the clock records the interval its result stays
correct for: the current second in the context's zone for `now` and durations
`ago`, or the current day for `today`, weekday phrases, month-name dates
without a year, and periods `ago`. A context that differs only in `now` keeps
the cache, so a later generation re-evaluates just the lines whose interval no
longer contains `now`, plus the lines that read their changed results.
`SheetEvaluation.nextRecalculation` is the earliest interval end, or `nil` when
no line read the clock.

Ranges in results are relative to each line's text. Edits above a line shift its
sheet position without invalidating its cached result or ranges.
