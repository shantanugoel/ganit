# Section 9 and manual release matrix

Status of the accessibility, internationalization, and macOS behavior
requirements (PLAN §9) and the manual release matrix (PLAN §11.5).

- **Automated** rows are enforced by the named tests on every CI run.
- **Implemented** rows are met by code but have no automated check.
- **Needs a person** rows require a human tester, real hardware, or system
  settings that tests cannot drive. They have not been run.

Last updated: 2026-09-15.

## 9.1 Accessibility

| Requirement | Status | Evidence |
| --- | --- | --- |
| Standard focus rings remain visible | Implemented | Standard AppKit controls; no custom focus drawing |
| Full Keyboard Access reaches every actionable element | Automated (menus); Needs a person (Tab order) | `AccessibilityAuditTests.everyContextMenuAndToolbarActionIsInTheMainMenu` |
| No mouse-only essential action | Automated | Same test: sidebar context menus and toolbar actions all have main-menu commands (Rename/Delete Folder, Move to Folder, Show Sidebar added for this gate) |
| VoiceOver: sidebar, text, answers, diagnostics, details | Automated (exposure); Needs a person (listening) | `TextAccessibilityTests.exposesAnswersAndFailuresToAccessibility`, `offersCustomActionsForAnswerInteractions` |
| Rotor for error/warning lines | Automated | Problems and Results rotors, Next/Previous Problem announcing the message: `movesBetweenProblemsWithCommandsAndRotors` |
| Hover/drag/gesture actions have menu or accessibility actions | Automated | Answer click/double-click have custom accessibility actions and menu commands |
| No live-answer chatter | Implemented | Answers are not posted as announcements while typing |
| Controls ≥ 20×20 pt | Automated | `AccessibilityAuditTests` workspace window and Quick Ganit audits |
| Image-only controls have accessibility labels | Automated | Same audits; toolbar items have labels |
| Text ≥ 10 pt, default 13–14 pt | Automated | Same audits; editor base size 14 pt |
| Editor/result text scales to 200% | Automated (scale); Needs a person (clipping) | `TextAccessibilityTests.scalesSourceAnswersAndColumnTogether` |
| Contrast ≥ 4.5:1; color never the only meaning | Automated (semantic colors only) | `VisualStyleTests` source scan; failures use dotted underlines and message text; see `docs/design/visual-system.md` |
| Reduce Motion / Reduce Transparency | Implemented; Needs a person | No custom animations or materials beyond system views |

## 9.2 Internationalization

| Requirement | Status | Evidence |
| --- | --- | --- |
| All UI strings localized | Implemented | String catalogs in `App/Resources` and `GanitFormatting/Resources` |
| Leading/trailing layout, natural alignment | Implemented | Constraint layout with leading/trailing anchors; `baseWritingDirection = .natural` |
| Mixed-direction source keeps exact offsets | Automated | `keepsBidirectionalAndSupplementaryTextOffsetsExact` |
| CJK marked text and composed characters | Automated | `mirrorsMarkedTextCompositionAndCommit`, `evaluatesAfterCompositionCommitsAndShowsTheNewestGeneration` |
| Localized digits, separators, minus signs | Automated | Engine lexer tests, `ResultFormatterTests` (`tr-TR`, `de-DE`) |
| Currencies and plural rules | Automated (currency display) | `formatsMoneyInLocaleStyleRoundedToMinorUnits` |
| Pseudolocalization and truncation | Automated (double-length strings); Needs a person (right-to-left review) | `PseudolocalizationTests.doubleLengthStringsFitWithoutClipping` lays out the workspace window, Quick Ganit, and shortcut settings with `NSDoubleLocalizedStrings`; `scripts/run-pseudolocalized.sh` opens the app doubled and right-to-left |

## 9.3 macOS behavior

| Requirement | Status | Evidence |
| --- | --- | --- |
| Standard window controls, multiwindow, menus, responder chain | Automated | `WorkspaceWindowControllerTests`, `MainMenuTests`, `standardActionsReachTheTextViewThroughTheResponderChain` |
| Services, Help menu | Automated (menus present) | `MainMenuTests` |
| Print | Automated | File ▸ Print… uses `SheetDocumentRenderer`, tested by `SheetDocumentRendererTests` |
| Sharing, Settings window, Help content | Not implemented | See docs/reference/known-limitations.md |
| Native text editing, dead keys, Find, undo grouping | Automated (Find, undo, marked text); Needs a person (dictation) | Editor tests |
| Customizable toolbar | Implemented | `NSToolbar` delegate with allowed items |
| State restoration, excluding transient state | Automated | `restoresTheWindowsSheetSelectionAndSidebar` |
| "Close windows when quitting" | Implemented | System restoration behavior |

## 11.5 Manual release matrix

| Row | Status | Evidence |
| --- | --- | --- |
| Minimum window size | Automated | `fitsSidebarSourceAndAnswersAtMinimumSizeAndSupportsFullScreen` at 640×400 keeps 200 pt of sidebar and a source column at least as wide as the answers; `keepsSourceWiderThanAnswersAtItsMinimumSize` does the same for Quick Ganit at 320×120 |
| Multiple displays | Automated (placement); Needs a person (real displays) | `QuickPanelGeometryTests.opensOnTheDisplayWithThePointerAndStaysOnIt`: Quick Ganit opens on the pointer's display, including displays at negative coordinates, and stays fully on small displays |
| Full screen and Spaces | Automated (window behaviors); Needs a person (entering full screen, switching Spaces) | Workspace windows declare `fullScreenPrimary`; Quick Ganit is `moveToActiveSpace` and `fullScreenAuxiliary` (`isAStandardFocusableFloatingPanelThatKeepsTextWhenHidden`) |
| State restoration | Automated | `restoresTheWindowsSheetSelectionAndSidebar` |
| Minimum (macOS 14) and latest macOS | Needs a person | Only the latest macOS has been run |
| Apple silicon | Automated | CI and development Macs are Apple silicon |
| Light/Dark × Increase Contrast × Reduce Transparency | Needs a person | |
| Reduce Motion | Needs a person | |
| 100%, 150%, 200% editor text | Automated (scaling); Needs a person (visual check) | `TextAccessibilityTests.scalesSourceAnswersAndColumnTogether` |
| VoiceOver and keyboard-only | Needs a person | |
| English, pseudolocalized, Arabic/Hebrew, CJK input, comma-decimal locale | Automated (engine and editor offsets, double-length layout); Needs a person (right-to-left review, real IMEs) | `PseudolocalizationTests`, editor offset tests, `ResultFormatterTests` |
| Offline, stale rate, malformed rate, no network | Automated | `RateRefresherTests`, `ECBRateValidatorTests`, `RateProvenanceTests` |
| Fresh install, upgrade/migration, restore from backup | Automated (backup restore, recovery); Needs a person (fresh install) | GanitDocuments tests |
