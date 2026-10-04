# Table review fix checks

Date: 2026-10-04.
Worktree: `/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`.
Branch: `tables`.

## Commits

The existing changes were checked and committed first as `31033c0`.
The subsequent fixes each have a plan update and a separate commit.

| Finding | Commit | Change |
| --- | --- | --- |
| R26 | `a400998` | Explain the preview override and restore the column rule. |
| R37 | `1e0676c` | Keep the preview in the input area. Show scrollbars. Remove duplicate grid borders. |
| R36 | `60e04e9` | Expose meaningful text, the actual selection and complete cell errors. |
| R24 | `88975ef` | Show the unsupported range pattern before failed input errors. |
| R02 | `4c8bbd3` | Reveal the mapped Find result without a focus change. |
| R19 | `9592f44` | Describe the actual selected rows after a review sort. |

Commit `63e07e6` removes the strict format error in preview cleanup.

## Native checks

The checks used a separate test app with sample data.
Its bundle ID was `com.shantanugoel.Ganit.TableFixReview20261004`.
New review sheets were added to its test library.

- Shopping: the preview showed five rows. A Milk quantity edit changed the
  total from ₹552 to ₹522. Tab, Escape and one Undo restored ₹552.
- Travel: the preview contained six rows, including SIM. Its totals gave
  separate EUR, INR and USD amounts. An arithmetic cell input became
  `=85 USD * 3` and showed $255.
- Portfolio: Find kept the complete BETA term and keyboard focus. Its
  preview identified `Portfolio`, `A3` and `Ticker`. Open Table selected
  A3. Gain sort placed the -$100 loss first without a source row move.
- Recipe: the preview contained Sugar. Changing `servings` from 6 to 8
  changed flour to 1,000 g and milk to 500 mL.
- Quote: the total was $810. The column rule form showed `rate = $60.00`
  and a $120 first-row result. The draft `=Hours * rate` gave a specific
  correction and disabled Apply.
- Study: savings showed 1,102.5. ROUND showed 3.33. The IF and multiple-range
  inputs gave specific diagnostics in the accessible cell labels.
- R37: native screenshots at 640 × 600 showed the preview input boundary,
  visible horizontal scrollbar and single row separators. A wide window
  check also confirmed the preview input boundary.

Evidence:

- [R37 sheet](persona-review-2026-10-04/r37-sheet.png)
- [R37 grid](persona-review-2026-10-04/r37-grid.png)
- [Find focus and mapped result](persona-review-2026-10-04/r02-find-result.png)
- [Column rule validation](persona-review-2026-10-04/r28-rule-validation.png)
- [Study accessibility record](persona-review-2026-10-04/r36-study-accessibility.txt)

## Automated checks

- The final full suite passed 1,130 tests.
- The review regression suite passed all 19 tests.
- The strict format check passed for all changed Swift files.
- The final debug app build and bundle checks passed.
- The native Find test failed during one combined run. It passed alone.
  The final full run passed with no concurrent native Find actions.

## Open check

R36 has a complete implementation and passing automated checks.
Its required VoiceOver speech check is still open.
Permission to enable VoiceOver temporarily was requested in this chat.
The issue must remain open until that check is complete.

The native checks did not include independent human usability trials.
