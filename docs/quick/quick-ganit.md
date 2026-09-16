# Quick Ganit

Quick Ganit is a floating panel for disposable calculations. It hosts the same
`SheetEditorViewController` as workspace sheets, so parsing, evaluation,
answers, decoration, and accessibility are identical.

## Panel

`QuickPanelController` uses a standard titled, closable, resizable `NSPanel`
with a transparent title bar: accessibility, focus, and window management
behave like any Mac panel.

- It is non-activating, so it takes keyboard focus above the frontmost app
  without bringing Ganit's other windows forward.
- It floats and does not hide when Ganit is inactive.
- It opens on the active Space, including over full-screen apps, instead of
  switching Spaces.
- Showing it centers it on the screen with the pointer, slightly above center,
  focuses its text, and selects any text kept from last time so typing
  replaces it.
- Escape hides it; the text stays for next time.

Window ▸ Quick Ganit always opens the panel. Launching Ganit with the
`--quick-ganit` argument, for example `open -a Ganit --args --quick-ganit`,
opens Quick Ganit instead of a sheet.

## Keys and promotion

- Return inserts a newline; lines evaluate as they do in sheets, each with its
  own answer, including the variables and units the
  [definitions sheet](../grammar/definitions.md) shares.
- ⌘Return copies the insertion point's displayed result, or the buffer's last
  result when that line has none, and hides the panel. Without any result it
  beeps and stays open.
- **Keep as Sheet** (⌘S, or the title-bar button) saves the buffer as a new
  library sheet, opens it in a workspace window, and activates Ganit. The
  buffer is then emptied and the panel hides.

## Keeping the buffer

By default Quick Ganit keeps its text: hiding the panel, the panel losing focus,
or quitting Ganit stores the buffer in `QuickBuffer.txt` beside the library,
replaced atomically, and a new launch restores it. The buffer is never added to
the library, backups, index, or search; clearing it removes the file.

Window ▸ Quick Ganit Starts Empty turns this off: the stored text is deleted,
nothing is stored afterward, and each time the panel opens it starts empty.

## Activation and the Dock

Showing, using, copying from, or dismissing Quick Ganit does not activate
Ganit, so the app that was frontmost keeps focus when the panel hides. Only
Keep as Sheet or opening the workspace activates Ganit. Closing the last
workspace window does not quit Ganit, so the shortcut keeps working; clicking
the Dock icon without workspace windows opens the most recently modified active
sheet, or a new sheet in an empty library.

## Global shortcut

As decided in [ADR 0008](../adr/0008-global-shortcut.md), Ganit has no default
global shortcut. Window ▸ Quick Ganit Shortcut… records one:

- A shortcut needs at least one modifier. `⌥Space` is suggested, not enabled.
- Before saving, the window lists known conflicts: enabled macOS shortcuts
  (from the system's symbolic hot keys), commands in Ganit's menus, and, when
  saving fails, another app already using it. Ganit never substitutes a
  different shortcut.
- No Shortcut removes it.

`GlobalHotKey` registers the shortcut with the Carbon hot key service, which
works in the App Sandbox without Accessibility or Input Monitoring permission
and delivers only the registered combination. The shortcut is a user default,
restored at launch; pressing it toggles the panel.
