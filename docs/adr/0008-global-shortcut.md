# ADR 0008: Require an explicit user-selected global shortcut

- Status: Accepted
- Date: 2026-09-14

## Context

Common global shortcuts collide with Spotlight, input-source switching, Finder, launchers, and character entry on localized keyboard layouts. Registration success alone does not prove that a shortcut is usable. Option-only combinations have also had inconsistent behavior across recent macOS releases. Ganit does not need Accessibility or Input Monitoring permission merely to offer Quick Ganit.

## Decision

- Do not activate a global shortcut by default.
- During onboarding, offer `⌥Space` as a suggestion only after showing known conflicts for the active system and keyboard layout. The user must confirm or record another combination.
- Reject bare keys and require at least one modifier. Warn on known system, menu, input-source, and application conflicts; never silently substitute a different shortcut.
- In Phase 6, use the least-privilege system registration mechanism that works in the App Sandbox without Accessibility or Input Monitoring permission. Validate it on macOS 14 and the current release before selecting the implementation.
- Keep Quick Ganit available through the app's Window menu when no global shortcut is configured.

## Consequences

- First launch has one explicit choice instead of an unreliable hidden default.
- Shortcut storage is a user preference, not source or calculation history.
- Conflict UX and localized keyboard testing are Phase 6 exit requirements.
- Ganit will not add event taps, key logging, or permission-heavy fallback paths.

## References

- [Keyboard shortcuts](https://developer.apple.com/design/human-interface-guidelines/keyboards#Keyboard-shortcuts)
- [Monitoring events](https://developer.apple.com/documentation/appkit/nsevent#Monitoring-Events)
