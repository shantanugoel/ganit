# Sample sheets

Paste a sample into a new sheet to try the tables. Each sample is one sheet's
plain source, exactly as a sheet stores it. A table starts at `@ganit-table 1`
and ends at `@end-ganit-table`, and Ganit reads the block as one table.

## Trip budget

A table with a rule column, a total, and prose that reads the table. Paste
this source into a new sheet, then use Edit ▸ Open Table to edit cells.

```text
days = 5

@ganit-table 1
{"ids":["0fe535e6-819e-4e63-ba17-0be85593a7f3","bb09c3ce-9e14-4036-848c-b36520299ec1","ca9c5863-f51b-4cc9-8823-1c7a9a702f01","b6df2df5-e723-4626-bfbc-e83c745c55e4","8a04c1bd-7851-4c26-8856-16fc6096b404","849cb53d-3797-45e2-9481-bca2be4a38d2","aeacf4c2-548f-4822-9f33-8be9faa714ab"],"t":0,"n":"Expenses","c":[{"i":1,"h":"Item","p":"text"},{"i":2,"h":"Cost per day","p":"value"},{"i":3,"h":"Days","p":"value"},{"i":4,"h":"Amount","p":"value","f":"=[@Cost per day] * [@Days]","z":"sum"}],"r":[5,6],"x":[{"a":[5,1],"s":"Hotel"},{"a":[5,2],"s":"85 USD"},{"a":[5,3],"s":"3"},{"a":[6,1],"s":"Meals"},{"a":[6,2],"s":"42.50 USD"},{"a":[6,3],"s":"3"}],"b":[]}
@end-ganit-table

total = sum(Expenses[Amount])
total / days
```

The Amount column has the rule `=[@Cost per day] * [@Days]`, and its total is
`sum`. Change a cost or a day count, and the Amount cells, the total, and the
two prose answers follow.

## Materials estimate

A unit-aware estimate. Qty holds quantities, and each Rate cell is a formula,
because a rate such as `240 / m` is arithmetic input and starts with `=`.

```text
@ganit-table 1
{"ids":["dec802da-5508-4136-b1ff-9317678d0615","c703f3bb-79cc-46e8-866e-39ce44882fb8","b01b87e9-ec5f-4a9f-b902-e0a8c266213a","7dbddd7f-c63f-402d-b6e9-df45ec9d7ca6","f6bc72a9-ced7-4edc-8f19-c3b9c2541b1c","79f3979a-3f86-4ab5-b2bf-2e4d9f77ff52","b4651ef0-359c-408a-a9e2-5c066c324591"],"t":0,"n":"Materials","c":[{"i":1,"h":"Material","p":"text"},{"i":2,"h":"Qty","p":"value"},{"i":3,"h":"Rate","p":"value"},{"i":4,"h":"Amount","p":"value","f":"=[@Qty] * [@Rate]","z":"sum"}],"r":[5,6],"x":[{"a":[5,1],"s":"Timber"},{"a":[5,2],"s":"12 m"},{"a":[5,3],"s":"=240 / m"},{"a":[6,1],"s":"Nails"},{"a":[6,2],"s":"2 kg"},{"a":[6,3],"s":"=90 / kg"}],"b":[]}
@end-ganit-table

sum(Materials[Amount])
```

The Amount rule is `=[@Qty] * [@Rate]`. The amounts keep compatible units, so
`sum(Materials[Amount])` answers `3,060`. Add a row with the same unit pair
and the total follows.

## Build a table of your own

Use Edit ▸ Insert Table, or paste a rectangle with Edit ▸ Paste as Table. Set
each column to Text or Value in the dialog. A value column accepts complete
literals such as `42.50 USD` and `12 m`; arithmetic input starts with `=`.
The commands are in [Calculation tables](../editor/tables.md) and the grammar
is in [table references](../grammar/table-references.md).
