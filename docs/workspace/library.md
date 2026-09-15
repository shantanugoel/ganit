# Library window

Each workspace window shows the library sidebar beside the open sheet's editor
in a standard `NSSplitViewController`. The toolbar holds the sidebar toggle, New
Sheet, and sheet search. The title is the open sheet's title.

## Sidebar

The upper list holds collections: **All Sheets**, **Recent** (modified in the last
seven days), **Favorites**, **Archive**, **Trash**, and user **Folders**. It sizes to
its rows and scrolls past 60% of the sidebar. The lower list shows the selected
collection's sheets, most recently modified first, with each title and a
relative modification time; toolbar search narrows it to sheets whose title or
source contains the text, ignoring case and diacritics.

All Sheets, Recent, Favorites, and folders list only active sheets; Archive and
Trash list archived and trashed sheets. Selecting a sheet saves the open sheet
and opens the selected one. A trashed sheet opens read-only.

## Commands

Commands apply to the clicked sheet during a context menu, or else to the
selected sheet, and appear in both the File menu and context menus.

| Command | Effect |
|---|---|
| New Sheet ⌘N | Creates an empty sheet, in the selected folder when one is selected, and opens it |
| New Folder ⇧⌘N | Creates and selects a folder |
| Rename… | Names the sheet; an empty name returns to the first-line title |
| Duplicate ⌘D | Copies the sheet into a new sheet in the same folder and opens it |
| Add to / Remove from Favorites | Toggles the favorite flag |
| Move to Folder | Moves the sheet into a folder or out of all folders |
| Archive, Move to Trash | Changes the sheet's state; if it was open, the first listed sheet opens |
| Unarchive, Put Back | Returns the sheet to active |
| Delete Immediately…, Empty Trash… | After confirmation, deletes trashed sheets with their backups |
| Rename Folder…, Delete Folder | Deleting a folder moves its sheets out of it |
| Search Sheets ⇧⌘F | Focuses the toolbar search field |

Organizing a sheet changes only its metadata; its source and modification time
are unchanged. Renaming sets `hasCustomTitle`, so saves keep the name.
