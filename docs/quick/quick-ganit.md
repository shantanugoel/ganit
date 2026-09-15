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
- Showing it centers it on the screen with the pointer, slightly above center,
  and focuses its text.
- Escape hides it; the text stays for next time.

Window ▸ Quick Ganit always opens the panel.

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
