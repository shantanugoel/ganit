# Calculation tables

Use Edit > Insert Table, or right-click the sheet and select Insert Table.
Select a blank table or a Shopping, Travel, Quote or Portfolio starter.
Enter the table name. Set the row count and column count. Set each column
header and input type, then select Insert. Automatic input is the default.
It reads numbers, percentages, units and money. It keeps ordinary labels as
text. Use Value to require a value, or Text to keep literal text. Use up to 32 columns and 4,000
cells. Value input reads numbers, percentages, units and money. Text input
keeps literal text. Formulas work in both types.
Use Automatic for most columns. Use Text for product codes, account numbers,
and labels that must stay as text. For example, Text keeps `00123` with its
leading zeros. Use Value for quantities, prices, and other calculation
inputs. Value reports an error if you enter a label. Value also supports a
default unit or currency.
Arithmetic and individual function arguments require values. If a reference
contains text or is blank, the error identifies that reference. For Text
columns, the error also gives the column name and tells you how to change
its input type. Range functions skip text and blank cells.
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
Enter saves the input and moves down. Tab discards the draft and moves right.
Shift-Tab discards the draft and moves left. Entry at the last row can add a
row. Escape discards the draft and clears the selection. A click outside the
table also clears the selection. Input-method
composition stays in the native field until you commit. Each committed edit
uses one document Undo step. Command-Z and Shift-Command-Z use document Undo
and redo.

Start a formula with `=`. In Automatic and Value columns, arithmetic such
as `85 USD * 3` also becomes a formula. Direct function input such as `sum(A2, B2)` adds
its leading `=` when you save. For example, enter `1` in A2 and `2` in B2.
Enter `sum(A2, B2)` or `=SUM(A2:B2)` in C2. The result is `3`. The first
data row is row 2; row 1 contains the column headers. While you edit, click a cell to insert its address.
Drag across cells to insert a range. The draft stays open. Reference lets you
enter an address or range with the keyboard. Complete offers range functions
current-row column references and available note definitions. Complete
starts a draft if necessary. Referenced cells use the accent color.

## Table Actions

The common toolbar has icon buttons for Undo, Redo, Copy, and Paste. These
buttons work in the sheet and table views. Use View > Show Toolbar to hide
or show this toolbar. Use View > Customize Toolbar to change its buttons.

Table controls appear in one row below the common toolbar. These controls
stay visible. Use the left arrow to return to the sheet. Hold the pointer
over an icon to see its command name.

Table Actions contains table commands: rename, add at the end and export.
Right-click a cell for cell commands. Right-click a row number or column
header for its commands. Insert rows above or below the selection. Insert
a column before or after the selection. Double-click a header to rename it.
Input Type selects Automatic, Text or Value. Column Settings sets a default unit or
currency for Value input. Click a row number or column header to select it.
Command-A selects all cells. Delete clears the selected cells.

Column Formula is an optional rule. It is not an input type. A cell can
hold its own formula without a column rule. Set Column Formula gives
a column one rule. For example, `=[@Qty] * rate` uses the Qty cell in each row
and a preceding definition named `rate`. The dialog lists column references
and note definitions. Its preview checks the proposed rule before Apply.
A failed rule cannot be applied. A dot marks a cell override in both views. Reset
Overrides removes selected overrides in rule columns. It preserves ordinary
input cells. Clear Column Formula removes the rule.

Command-C copies inputs and formulas. Copy Values copies displayed values. Copy Full Precision preserves numeric
precision. Copy Inputs and Formulas carries the source and its reference bindings. Paste
from Ganit translates copied formulas for the new location. External tab-separated input is data. If it contains formulas, choose
Formulas, Text or Cancel. Text keeps a formula as literal text. A paste can add rows or columns
within the insertion size limits. The paste and growth use one Undo step. Use Paste TSV as Formulas to treat external text
that starts with `=` as formulas. Fill uses the selected source cell and the
selected rectangle. Fill Down copies the top cell of each selected column.
Fill Right copies the first cell of each selected row. Command-D and
Command-R run these commands. Copied formulas move relative references;
`$A$2`, `$A2` and `A$2` keep their locked parts. Column Total adds a typed total below the grid. The
selection summary gives the range, row count, column count and cell types.
It gives a typed sum and average only when the selection has numeric values.
Fill keeps the selected range.

Export Table writes the open table as a tab- or comma-separated file. Select CSV or TSV in File format. The extension follows this choice.
Choose Values for the displayed values, Inputs and Formulas for the stored
sources, or Error Report for cell addresses, inputs and error explanations.
The dialog gives the number of failed cells before export. A column rule appears in every cell that inherits it. The totals
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

## Review and display

Use the column menu to sort ascending or descending. Equal values keep
source order. Different currencies and incompatible value types stay in
separate groups. Filter keeps rows whose input, text or currency code
contains the specified text. The summary gives the number of hidden rows.
Totals include all source rows. Sort and filter keep cell identities and
formula targets. Clear them before Fill, rectangular paste or row insertion.
You can edit and clear selected cells while a review view is active.

Use Freeze Label Column to keep one label column visible during horizontal
scroll. Select another column to change the frozen column. These settings
are saved in the sheet. Each change uses document Undo.

Select Display Format > Percentage, or use Column Settings, to show ratios
as percentages. Choose 0 to 12 decimal places. For example, `=1 / 10` with
two decimal places displays `10.00%`. The stored value stays `0.1`. Select
Automatic to remove this display format.

A sum of different currencies gives one total for each currency. It does
not convert them. Filter by a currency code to review that group. Use an
explicit conversion in a formula if you need one currency total.

To replace a selected tab-separated list, use Edit > Convert Selection to
Table. Check the proposed headers and rows, then select Insert. Conversion
removes the selected list. One Undo restores it.

## Results and errors

The grid uses the sheet number format. Pending means that the edited source
has no matching result yet. It does not show an old answer for new input.

Show Interpretation gives the source, error and calculation context. Repair
Broken Reference selects the full broken operand in the draft. Pick its new
target, then commit. Go to Original Failure opens the source of a blocked
result. Undo can restore the previous input after an error.

In the sheet preview, double-click a cell to edit it. Enter saves the input.
Tab discards the draft and moves to another cell. Escape or a click outside
the table discards the draft and clears the selection. Open Table opens the selected cell in the full
grid. The preview has all rows and columns. Scroll it in either direction to see
more cells. Long notes wrap. Headers keep their names. The preview height
shows five complete rows where the sheet has enough space.

The expanded grid uses the sheet source and document Undo. It does not have
a separate editable store. See the
[M4 test report](../design/tables/m4-editor-evidence.md) for verified behavior
and remaining release checks.

## Try it

Paste a ready sheet from the [sample sheets](../samples/tables.md) into a new
sheet, then open its table and edit cells.
