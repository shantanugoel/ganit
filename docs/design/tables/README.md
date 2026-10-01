# Calculation table visual references

Saved 2026-10-01 from the table concept discussed in the investigation. These
are design references, not screenshots of an implemented Ganit feature.

- [Implementation plan](../../plans/tables-implementation.md)
- [Investigation](../tables-investigation.md)
- [Interactive concept](concept.html)
- [Editable fragment](concept.fragment.html)

## Within a sheet

![An Items table between assumptions and dependent calculations](within-sheet.jpg)

Keep context and table calculations together; use the existing answer placement
outside the table. Selecting an Amount cell exposes its calculated-column rule.

## Expanded table

![The same table occupying the editing pane](expanded-table.jpg)

Expose row/column addresses for concentrated editing. Production must add a
Return to Sheet command and editable formula/reference-picking behavior.

## Using the concept

Open `concept.html` in a modern browser. The bottom view picker switches
between the two layouts. Quantity and price edits update Amount, totals and
the per-person result; Add row inherits the fixed calculation rule. Show
formulas displays local A1 spellings. The layouts share the same data.

The concept does not parse arbitrary formulas or call the Ganit engine. The
formula field is read-only, and its fixed INR arithmetic/validation is only
for exploring the layout. The implementation plan defines production behavior,
error rules, native keyboard/accessibility requirements and reference integrity.

Both JPEG references use the default three-row data and the browser's active
light appearance. The interactive reference follows the active light/dark
appearance. No application build is needed to use these files.

`concept.fragment.html` is the editable source; `concept.html` is a generated
standalone wrapper with bundled styles and interaction helpers. Regenerate
the latter after editing the fragment with the visualization skill's
`scripts/render.py <fragment-path> <output-path> --force`, when available.
Keep the screenshots in sync with the default layouts after visual changes.
