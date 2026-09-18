# Library window

Each workspace window shows the library sidebar beside the open sheet's editor
in a standard `NSSplitViewController`. The toolbar holds the sidebar toggle, New
Sheet, and sheet search. The title is the open sheet's title.

## Sidebar

The upper list holds collections: **All Sheets**, **Recent** (modified in the last
seven days), **Favorites**, **Archive**, **Trash**, and, once there is one to
name, user **Folders**. It sizes to
its rows and scrolls past 60% of the sidebar. The lower list shows the selected
collection's sheets, most recently modified first, with each title and a
relative modification time, rewritten every minute while the window is open so
it never says "1 second ago" an hour later. An empty list says why it is empty,
such as `No sheets match “rent”`. Toolbar search narrows it to sheets whose title or
source contains the text, ignoring case and diacritics.

All Sheets, Recent, Favorites, and folders list only active sheets; Archive and
Trash list archived and trashed sheets. Selecting a sheet saves the open sheet
and opens the selected one. A trashed sheet opens read-only.

## The scratch sheet

Every library holds one sheet at a well-known ID, titled **Scratch**, created
when the library opens. It is somewhere to work a number out without naming or
filing it first, so **Window ▸ Scratch** (⇧⌘S) and the menu bar item both open
it, and it cannot be renamed, archived, trashed, or deleted; `deletePermanently`
refuses its ID. It is an ordinary sheet in every other way, and can be
duplicated, favorited, and filed.

## Commands

Commands apply to the clicked sheet during a context menu, or else to the
selected sheet, and appear in both the File menu and context menus.

| Command | Effect |
|---|---|
| New Sheet ⌘N | Creates an empty sheet, in the selected folder when one is selected, and opens it. One nothing is written in and nobody names is discarded when it is left |
| Open in New Window | Opens the sheet in a new window, or brings forward the window showing it |
| New Folder ⇧⌘N | Creates and selects a folder |
| Rename… | Names the sheet; an empty name returns to the first-line title |
| Duplicate ⌘D | Copies the sheet into a new sheet in the same folder and opens it |
| Add to / Remove from Favorites | Toggles the favorite flag |
| Move to Folder | Moves the sheet into a folder or out of all folders |
| Archive, Move to Trash | Changes the sheet's state; if it was open, the first listed sheet opens. Both are disabled for the scratch sheet |
| Unarchive, Put Back | Returns the sheet to active |
| Delete Immediately…, Empty Trash… | After confirmation, deletes trashed sheets with their backups |
| Rename Folder…, Delete Folder | Deleting a folder moves its sheets out of it |
| Search Sheets ⇧⌘F | Focuses the toolbar search field |

Organizing a sheet changes only its metadata; its source and modification time
are unchanged. Renaming sets `hasCustomTitle`, so saves keep the name.

## Windows and open sheets

`Workspace` owns the library, every workspace window, and the open sheets. An
open sheet keeps its editor, text storage, answers, and undo history while Ganit
runs, so switching a window to another sheet and back returns to the same text
and undo stack. A sheet is shown in at most one window; selecting a sheet that
another window shows brings that window forward.

## Undo

Text edits undo through each sheet's own undo manager. Rename, favorite, Move to
Folder, Archive, Move to Trash, Unarchive, and Put Back are undoable through the
window's undo manager: undo returns the sheet's title, favorite flag, folder,
and state to their previous values. Creating sheets and folders is reversed by
trashing or deleting them. Delete Immediately and Empty Trash are confirmed
first and cannot be undone.

When a sheet's metadata changes while it is open, its autosaver adopts the new
metadata, so a later save of pending edits cannot write back an old folder,
favorite flag, or state.

## State restoration

Workspace windows are restorable through `WorkspaceRestoration`. Each window
records its sheet, collection, search text, text selection, scroll position, and
whether the sidebar is collapsed; the split view's autosave name keeps the
sidebar width, which stays between 150 and 280 pt because a title and a date
are all it lists. The library opens before restoration, and Ganit opens the most
recent sheet only when no window was restored.


## Export, print, and Quick Look

**File ▸ Export…** writes the open sheet as:

- **Ganit Sheet** — a `.ganit` package, which also carries
  `QuickLook/Preview.pdf` and `QuickLook/Thumbnail.png`. The system's package
  previewer shows these in Finder and Quick Look, so no Quick Look extension
  is needed; import ignores them.
- **Plain Text** — the source exactly as written.
- **PDF** — source beside answers, paginated like printing.
- **CSV** — `Line,Source,Answer,Status` rows quoted per RFC 4180. A cell that a
  spreadsheet would run as a formula (starting with `=`, `+`, `-`, `@`, tab, or
  return, and not a plain number) gets a leading apostrophe.
- **HTML** — a standalone page with one escaped table row per line that loads
  nothing.

**File ▸ Print…** (⌘P) prints the same layout as the PDF. Every format uses the
answers the editor shows once evaluation settles (`exportedLines()`), including
exchange rates and definitions, and reports failures with their messages
rather than hiding them. CSV status is `none`, `calculated`, `ai-unverified`,
`failure`, or `pending`. Assisted display answers carry “AI; unverified” in
HTML, PDF, print, and Quick Look previews. Plain Text remains source only.
`SheetDocumentRenderer` produces all of them.

## Spotlight

**Ganit ▸ Show Sheet Titles in Spotlight** is off by default. When it is on,
`SpotlightTitleIndex` gives Spotlight the title of each active sheet, and
nothing else: no source, answers, folders, or dates, and no archived or
trashed sheets. Choosing a result opens that sheet in a window.

The library reports every save, organizing change, import, and deletion
(`SheetLibrary.sheetsDidChange`), and the index sends Spotlight only the titles
that changed and the sheets that are gone. Its first update after launch
replaces everything in Ganit's Spotlight domain, so sheets deleted while the
app was closed disappear too. Turning the option off removes every item.
