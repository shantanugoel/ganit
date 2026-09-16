# Menus and commands

`MainMenu.install(in:)` builds the standard main menu. It lists only commands
that exist; Settings, sidebar, toolbar, Open, Export, and Quick Ganit items
arrive with those features. Every item uses a responder-chain action, so it is
enabled only when the focused editor or window can perform it.

| Menu | Items |
|---|---|
| Ganit | About, Check for Updates…, Check for Updates Automatically, Stay in the Menu Bar, Show Sheet Titles in Spotlight, Assistant…, Services, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q |
| File | New Sheet ⌘N, Close ⌘W, Print… ⌘P |
| Edit | Undo ⌘Z, Redo ⇧⌘Z, Cut ⌘X, Copy ⌘C, Paste ⌘V, Delete, Select All ⌘A, Find ▸ (Find… ⌘F, Find and Replace… ⌥⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for Find ⌘E) |
| Calculate | Copy Result ⇧⌘C, Copy Full Precision ⌥⇧⌘C, Show Interpretation, Insert Reference ⌘\, Insert Subtotal ⌘T, Recalculate ⌘R, Stop ⌘. |
| Format | Heading, Comment ⌘/, Divider, Step Number Up ⌃↑, Step Number Down ⌃↓, Number Format, Group Digits, Prose Mode |
| View | Bigger ⌘+, Smaller ⌘-, Actual Size ⌘0, Show Answer Separator, Enter Full Screen ⌃⌘F |
| Window | Minimize ⌘M, Zoom, Scratch ⇧⌘S, Definitions ⌘⇧D, Quick Ganit items, Bring All to Front, and the window list |
| Help | Ganit Help ⌘?, menu search |

`SheetCommands` declares the sheet actions. The text view handles result,
reference, and formatting commands; the editor controller, next in the
responder chain, handles Recalculate and Stop. New Sheet opens a workspace
window with an empty sheet.

- **Step Number Up** and **Step Number Down** step the number at the insertion
  point by one unit of its last decimal place, and are what a person who does
  not drag uses instead of scrubbing; see docs/editor/text-view.md.
- **Number Format** and **Group Digits** say how the open sheet writes its
  answers. The workspace window handles them, because the choice stays with the
  sheet; see docs/engine/result-formatting.md.
- **Insert Reference** inserts `line N` for the selected answer when it is above
  the insertion point, or else for the nearest line above with a result.
- **Insert Subtotal** and **Divider** add `subtotal` or `---` on a new line after
  the insertion point's line.
- **Heading** and **Comment** add `# ` or `// ` to every non-blank selected line
  after its indentation, or remove the marker when all of those lines already
  have it, as one undoable edit.
- **Stop** cancels the running generation and keeps the last shown answers.

## Return

Return inserts a newline, as in any text view. ⌘Return copies the insertion
point's result, the sheet counterpart of Quick Ganit's copy-and-dismiss.
