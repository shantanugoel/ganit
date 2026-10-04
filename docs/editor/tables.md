# Calculation tables

Use Edit > Insert Table, or right-click the sheet and select Insert Table.
Enter the table name. Set the row count and column count. Set each column
header and input type, then select Insert. Use up to 32 columns and 4,000
cells. Value input reads numbers, percentages, units and money. Text input
keeps literal text. Formulas work in both types.
Definitions above the table are available to its formulas. Definitions below
it are not available.

Use Edit > Open Table, or Shift-Command-T, to open a table at the insertion
point. If necessary, select a table from the menu. Return to Sheet restores
the prose selection and scroll position. Open Table restores the table
selection and scroll position.

## Select and edit

Click a cell to select it. Drag to select a rectangle. Use arrow keys to move
between cells. Hold Shift to extend the selection. Tab and Shift-Tab move
between columns and then rows.

Press Return or F2, double-click a cell, or type to edit at the cell. The
formula bar shows the same input. You can also edit in the formula bar.
Return saves the input and moves down. Tab saves and moves right. Shift-Tab
saves and moves left. Entry at the last row can add a row. Escape cancels. Input-method
composition stays in the native field until you commit. Each committed edit
uses one document Undo step. Command-Z and Shift-Command-Z use document Undo
and redo.

Start a formula with `=`. Direct function input such as `sum(A2, B2)` adds
its leading `=` when you save. For example, enter `1` in A2 and `2` in B2.
Enter `sum(A2, B2)` or `=SUM(A2:B2)` in C2. The result is `3`. The first
data row is row 2; row 1 contains the column headers. While you edit, click a cell to insert its address.
Drag across cells to insert a range. The draft stays open. Reference lets you
enter an address or range with the keyboard. Complete offers range functions
and current-row column references. Referenced cells use the accent color.

## Table Actions

Table Actions contains table commands: rename, add at the end and export.
Right-click a cell for cell commands. Right-click a row number or column
header for its commands. Insert rows above or below the selection. Insert
a column before or after the selection. Double-click a header to rename it.
Input Type changes Text or Value. Column Settings sets a default unit or
currency for Value input. Click a row number or column header to select it.
Command-A selects all cells. Delete clears the selected cells.

Column Formula is an optional rule. It is not an input type. A cell can
hold its own formula without a column rule. Set Column Formula gives
a column one rule. For example, `=[@Qty] * rate` uses the Qty cell in each row
and a preceding definition named `rate`. A dot marks a cell override. Reset
Overrides removes selected overrides in rule columns. It preserves ordinary
input cells. Clear Column Formula removes the rule.

Command-C copies inputs and formulas. Copy Values copies displayed values. Copy Full Precision preserves numeric
precision. Copy Inputs and Formulas carries the source and its reference bindings. Paste
from Ganit translates copied formulas for the new location. External tab-separated input is data. A paste can add rows or columns
within the insertion size limits. The paste and growth use one Undo step. Use Paste TSV as Formulas to treat external text
that starts with `=` as formulas. Fill uses the selected source cell and the
selected rectangle. Fill Down copies the top cell of each selected column.
Fill Right copies the first cell of each selected row. Command-D and
Command-R run these commands. Copied formulas move relative references;
`$A$2`, `$A2` and `A$2` keep their locked parts. Column Total adds a typed total below the grid. The
selection summary shows a typed sum and average when the values permit them.

Export Table writes the open table as a tab- or comma-separated file. Choose
Values for the displayed values, or Inputs and Formulas for the stored
sources. A column rule appears in every cell that inherits it. The totals
footer is the last row. The header row follows the Include header row choice.
The CSV separator follows the sheet's number locale, so a decimal comma uses
a semicolon. A field that a spreadsheet would run as a formula starts with
an apostrophe, which keeps `-`, `+`, `=`, and `@` text safe to open in
another app. Numbers are not formulas: a value the sheet displays as
`-2,100`, or as `-1,5` in a decimal-comma locale, stays a number in the
export. Remove the apostrophe to run that formula.

Print, PDF, HTML, and the Quick Look preview of an exported package show
each table as a grid with its headers, its values with their units, and
error messages in place. A header row repeats when a table continues on the
next printed page. The block's source stays in plain-text export and in
Inspect Table Source.

## Results and errors

The grid uses the sheet number format. Pending means that the edited source
has no matching result yet. It does not show an old answer for new input.

Show Interpretation gives the source, error and calculation context. Repair
Broken Reference selects the full broken operand in the draft. Pick its new
target, then commit. Go to Original Failure opens the source of a blocked
result. Undo can restore the previous input after an error.

In the sheet preview, double-click a cell to edit it. Return or Tab saves
the input. Escape cancels. Open Table opens the selected cell in the full
grid. The preview shows up to five rows and eight columns.

The expanded grid uses the sheet source and document Undo. It does not have
a separate editable store. See the
[M4 test report](../design/tables/m4-editor-evidence.md) for verified behavior
and remaining release checks.

## Try it

Paste a ready sheet from the [sample sheets](../samples/tables.md) into a new
sheet, then open its table and edit cells.
