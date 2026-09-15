# Line references and aggregates

Expressions can use results from lines above them. References never point
downward, so a sheet cannot contain a reference cycle.

| Form | Meaning |
|---|---|
| `line 3` | the result of sheet line 3 (one-based) |
| `previous`, `prev` | the nearest result above in the current block |
| `sum`, `total` | the sum of results in the current block |
| `subtotal` | the sum of results since the previous subtotal in the block |
| `average`, `avg` | the sum divided by the count |
| `median` | the middle result, or the mean of the two middle results |
| `count` | the number of results |

`line N` counts physical sheet lines, including blank lines, comments, and
headings. It follows the text: inserting a line above shifts which line a
number names.

## Blocks

A block is the run of lines after the most recent blank line, heading, or
divider. `previous` and aggregates read only the current block; `line N` may
read any line above. Comment and label-only lines do not end a block.

Aggregates skip lines that themselves contain an aggregate, so a `total` below
subtotals does not count values twice:

```text
1
2
subtotal     // 3
3
4
subtotal     // 7
total        // 10
```

A line counts once its expression has a result, including variable
declarations.

## Values and errors

Aggregated results must have the same value kind. Numbers and percentages sum
exactly; quantities sum dimensionally in the first result's unit, and median
compares quantities after converting them to that unit. Mixing kinds fails with
`evaluation.typeMismatch`.

Errors never count as zero. If any line an aggregate or reference would read
failed, including an incomplete line, the reference fails with
`evaluation.unavailableReference`. A reference to a line with no expression,
to the current line or below, or an average or median of an empty block, fails
with `evaluation.invalidReference`. `sum`, `subtotal`, and `count` of an empty
block are `0`.

The parser treats references as numbers when choosing phrase grammar, so use
parentheses or a variable for percentage phrases over a referenced percentage.

## Selecting lines instead

Selecting lines in the editor shows their count, total, and average in a
[summary bar](../editor/text-view.md) without writing anything. A selection is
not a block: it counts every answer it touches, in any order, across blank
lines, headings, and dividers, and it reads the answers already on screen. The
values themselves are aggregated by the same rules as above.
