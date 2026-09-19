# Menus and commands

`MainMenu.install(in:)` builds the standard main menu. It lists only commands
that exist; sidebar, toolbar, Open, Export, and Quick Ganit items arrive with
those features. Every item uses a responder-chain action, so it is enabled only
when the focused editor or window can perform it.

| Menu | Items |
|---|---|
| Ganit | About, Settings… ⌘,, Check for Updates…, Check for Updates Automatically, Stay in the Menu Bar, Show Sheet Titles in Spotlight, Assistant…, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q |
| File | New Sheet ⌘N, Close ⌘W, Print… ⌘P |
| Edit | Undo ⌘Z, Redo ⇧⌘Z, Cut ⌘X, Copy ⌘C, Paste ⌘V, Delete, Select All ⌘A, Find ▸ (Find… ⌘F, Find and Replace… ⌥⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for Find ⌘E), Go to Line… ⌘L, Autocomplete |
| Calculate | Copy Result ⇧⌘C, Copy with Results, Copy Full Precision ⌥⇧⌘C, Show Interpretation, Ask Assistant, Change Answer…, Cancel Request, Insert Reference ⌘\, Insert Subtotal ⌘T, Recalculate ⌘R, Stop ⌘. |
| Format | Heading, Comment ⌘/, Divider, Step Number Up ⌃↑, Step Number Down ⌃↓, Number Format, Group Digits, Group Digits in Lakhs, Angles in Degrees, Decimal Comma (1.234,56), Markdown Mode, Dollar Means |
| View | Bigger ⌘+, Smaller ⌘-, Actual Size ⌘0, Show Answer Separator, Show Line Numbers, Enter Full Screen ⌃⌘F |
| Window | Minimize ⌘M, Zoom, Scratch ⇧⌘S, Definitions ⌘⇧D, Quick Ganit items, Bring All to Front, and the window list |
| Help | Ganit Help ⌘?, Release Notes, Show Tour, Report a Problem…, menu search |

The first time Ganit opens a sheet it shows a short tour. Skip or Done
dismisses it; Settings and Help ▸ Show Tour open it again.

Settings also holds choices no menu has: Appearance keeps windows Light or Dark
instead of following the Mac (System, the default), and Open Ganit at Login
adds Ganit to the Mac's login items.

The sheet's right-click menu is the same sheet commands plus Cut, Copy, Paste,
and Select All. It does not include AppKit Font, Spelling, Speech, or Services
items.

`SheetCommands` declares the sheet actions. The text view handles result,
reference, formatting, and Ask Assistant commands; the editor controller, next
in the responder chain, handles Recalculate and Stop. New Sheet opens a
workspace window with an empty sheet.

- **Ask Assistant** sends the insertion point's line, or the selected answer's,
  to the configured assistant again: a line Ganit could not work out, or an
  `ask_assistant` prompt. See docs/editor/assistant.md.

- **Change Answer…** offers saving a reviewed correction into sheet source
  (with the original line retained as a comment), or using it temporarily until
  Ganit quits. Neither option sends another request.

- **Cancel Request** stops waiting for the insertion point's line, or the
  selected answer's, while it shows Asking…. The line shows its diagnostic
  again and is not asked about again until Ask Assistant.

- **Copy with Results** copies each selected line, or the insertion point's
  line, with the answer that line shows. Assisted display answers include an
  “AI; unverified” annotation; pending requests are omitted.

- **Step Number Up** and **Step Number Down** step the number at the insertion
  point by one unit of its last decimal place, and are what a person who does
  not drag uses instead of scrubbing; see docs/editor/text-view.md.
- **Ganit Help** opens the reference at a readable size, lists every built-in
  unit under Units, and answers everyday words such as mortgage or GST. A
  search with no match suggests one word to try and `ask_assistant(…)`.
- **Number Format** (automatic, whole numbers, two or four decimals,
  scientific, hexadecimal, binary, fractions), **Group Digits**, and **Group
  Digits in Lakhs** (`12,34,567`) say how the open sheet writes its answers.
- **Answer Format** on an answer's right-click menu writes that one answer in
  any Number Format, or in the sheet's again with **Sheet Default**. The choice
  is stored in the sheet's display options by the line's trimmed text, so it
  survives reopening and moving the line, and editing the line drops it.
- **Angles in Degrees** reads the sheet's bare angles as degrees, so `sin(90)`
  is `1`; an angle with its unit, `sin(30°)`, is read in that unit either way.
- **Show Line Numbers** numbers each physical line in a gutter, counting as
  `line N` and diagnostics do; wrapped rows share their line's number. It is
  kept with the sheet's display options. **Go to Line…** (⌘L) moves the
  insertion point to a line by that number and flashes it.
- **Decimal Comma (1.234,56)** reads and writes the sheet's numbers with a
  decimal comma and point grouping, and `;` or `, ` between arguments. It
  stores the sheet's locale as `en-DE`: English words, German separators. A
  new sheet starts with it on when this Mac's region writes a decimal comma. The workspace window handles them, because the choice stays with the
  sheet; see docs/engine/result-formatting.md.
- **Insert Reference** inserts `line N` for the selected answer when it is above
  the insertion point, or else for the nearest line above with a result.
- **Insert Subtotal** and **Divider** add `subtotal` or `---` on a new line after
  the insertion point's line.
- **Heading** and **Comment** add `# ` or `// ` to every non-blank selected line
  after its indentation, or remove the marker when all of those lines already
  have it, as one undoable edit.
- **Stop** cancels the running generation, keeping the last shown answers, and
  cancels every assistant request of the sheet as Cancel Request does.

## Return

Return inserts a newline, as in any text view. ⌘Return copies the insertion
point's result, the sheet counterpart of Quick Ganit's copy-and-dismiss.
