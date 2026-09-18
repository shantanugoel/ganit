Goal set: Behave like a power user of macOS, and a student and an expert in various domains including, but not limited to, electronics, science, computers, physics, maths, literature, finance, traveler, general housemaker etc, and use ganit app with computer use in all of these capacities. The main intent behind this is to figure out app UI/UX/functionality issues that can bite any users. Finally present a table of these issues with their description, severity, priority, complexity, RoI etc and they should be sorted in order in which they should be fixed

Goal acknowledged: I'll use Ganit across many domains as a power user, then give you a ranked table of issues. First I'll look at the project and see what tools I have for driving the app.

Both builds are stale; building the current HEAD so I test what's actually on main.

Ganit isn't running. I'll launch the fresh 0.2.2 build and request control of it.

Let me start as a household budgeter: new sheet, then a realistic monthly budget.

Background AX control is flaky for a text-heavy app and skips real keystrokes, which could hide bugs. Switching to full-screen control for a faithful power-user test.

Still setting up: making the Ganit window bigger so I can read results clearly, then I'll start typing test scenarios.

Early finding already: on a wide window the answers sit ~1,300px away from their lines. Resizing to a normal size and continuing.

I'll work with the default window size and zoom in on it instead.

I noticed truncated error text, spell-check issues under keywords like `sum`/`average`, and a failing `sum` due to an error on the line above. To cover more ground quickly, I'll also check the bundled `ganit` CLI, which uses the same engine as the GUI.

Progress: budget pass done (found ratio-as-% and mixed-currency gaps). Now running a broad domain battery — electronics, physics, CS, maths, travel, cooking, dates, finance.

I've finished 4 domain test batteries with the engine, logging dozens of gaps—like missing units support (volts/amps/ohms), `16/09/2026` silently dividing, and price-per-kWh failing. Next I'll test finance functions and labels/variables before returning to the GUI for UX flows.

The engine sweep turned up several issues—reserved words like `total`, `count`, `min`, `max` can't be used as variable names, `10000 * 1.05^10` prints with excessive decimal precision, and Indian number grouping breaks `pmt`. I'll now shift focus to GUI/UX aspects: error hovering, copying answers, menus, search, and sheet management.

Big find while hovering an error: instead of the full error text, the tooltip shows AppKit's internal debug dump of `SheetTextView` (frame, MaxSize 1.79e308…). Checking the code for the cause.

Found it: `SheetTextView` implements the tooltip method but never conforms to `NSViewToolTipOwner`/`@objc`, so AppKit ignores it and shows the view's `description` instead — breaking all truncated-text and hover tooltips. Moving on to check right-click menus.

Context menu shows **"Show Interpretation" twice**. Clicking it to see what it reveals.

The interpretation popover shows a vague "unexpected token" error without highlighting the problematic part or suggesting a fix. I'll check the menus next to find more features to test.

I've reviewed the settings (sparse - no options for default decimals, locale/grouping, angle mode, or fonts). Next I'll test real keystroke typing with autocomplete enabled, since my earlier input used paste which bypasses it.

I found a serious typing bug: entering "2 h 15 min" and pressing Return triggered an unwanted autocomplete for the `min(x, y)` function, garbling the sheet and sending broken lines to the assistant. I'll wait to see how it settles before continuing.

Confirmed the bug: `insertNewline` always accepts a visible completion, so it wrongly autocompletes an already-complete word like "min". Next, I'll check Help, search, and Quick Ganit.

Help has no catalogue of supported units, and searches like "mortgage" dead-end. Checking Quick Ganit next.

Found a bug: Quick Ganit re-opens with leftover text (`1+2`) unselected, so new input like `18% of 2499` gets concatenated into a silently wrong result. I'll test Escape and re-summoning to see if that resolves it.

Found two more issues: Escape doesn't dismiss Quick Ganit, and one assistant reply is just leaked reasoning-model chatter ("End of thought process") instead of an actual answer. I'll check how assistant replies get cleaned before display.

Found the root cause: AssistantReply.swift falls back to the reasoning text's last line when content is empty, so "End of thought process." gets used as the answer. Now I'll check whether line 6 references still hold after inserting a line above.

Quick Ganit also stays floating over the main window after I click away, covering answers. Closing it.

I've confirmed the silent error: inserting `phone = 60` shifted `savings = salary - line 6` to subtract Netflix instead of the subtotal, spiking savings from 4,449.51 to 7,484.51 with no warning. I'll check whether the references are supposed to stay stable.

Documented as intentional ("line N follows the text"), but it's still a silent-wrong-answer trap worth listing. Now checking Copy with Results output and Markdown Mode.

Copy with Results uses tab separators (fine for spreadsheets, ragged in chat/notes). Toggling Markdown Mode.

In Markdown Mode the `savings / salary as %` error silently disappears (the line is treated as prose), and the `average` answer renders on the line below. Reverting and checking undo.

Found a formatting bug where exact decimals either keep the input scale or explode (e.g., `100 * 1.25` → `125.00`, `1.1^20` → `6.72749994932560009201`). Next, I'll do one more GUI check for a long line colliding with the answer column and test sidebar search.

Search works on sheet text but gives no "No results" message and doesn't highlight matches in the open sheet. I have enough coverage; cleaning up my three test sheets (moving to Trash, recoverable).

Cleanup done (the three test sheets are in Ganit's Trash). Writing up the ranked results.

I tested the current `main` build (0.2.2) by hand in the app: a household budget, a Japan trip sheet, Quick Ganit, Help, Settings, Markdown Mode, search, copy and the context menus. I also ran about 250 expressions through the bundled `ganit` command, which uses the same engine. The areas covered were electronics, physics, chemistry, computing, maths, travel, cooking, household, finance, literature and student work.

## Worst problems

1. **Hovering an answer shows developer junk.** Instead of the full error text, the tooltip shows an internal dump of the text view (`<GanitEditorUI.SheetTextView: 0x…> Frame = … MaxSize = {1797693…}`). The code has the tooltip method, but `SheetTextView` never declares `NSViewToolTipOwner`, so macOS can't find it. Every cut-off answer, error and hover-help tooltip is affected.
2. **Return picks an autocomplete suggestion even when the word is already finished.** I typed `distance / 2 h 15 min`, then Return. It inserted the `min(x, y)` function, pulled my next line inside the brackets and left a stray `, y)`.
3. **Quick Ganit gives wrong answers from leftover text.** It reopened with `1+2` still there and nothing selected. Typing `18% of 2499` produced `1+218% of 2499 = 5,448.82`. Escape didn't close it, and it stayed on top of the main window.
4. **The assistant can show a made-up answer.** When the model's reply is empty, the app uses the last line of the model's reasoning instead. One line got "End of thought process" in purple as its answer.

## All issues, in the order to fix them

| # | Issue | What happened | Severity | Priority | Effort | Payoff |
|---|---|---|---|---|---|---|
| 1 | Tooltip shows the view's debug dump | Hovered any cut-off error. Fix: add `NSViewToolTipOwner` in [SheetTextView.swift:546](Sources/GanitEditorUI/SheetTextView.swift:546) | High | P0 | XS | ★★★★★ |
| 2 | Return accepts a completion for a finished word | `2 h 15 min` + Return → `min(` inserted and the next line swallowed ([SheetTextView.swift:776](Sources/GanitEditorUI/SheetTextView.swift:776)) | Critical | P0 | S | ★★★★★ |
| 3 | Quick Ganit adds to old text without selecting it | `1+2` + `18% of 2499` → 5,448.82 | Critical | P0 | XS | ★★★★★ |
| 4 | Assistant uses the model's reasoning as the answer | "End of thought process" shown as an answer ([AssistantReply.swift:9](Sources/GanitData/AssistantReply.swift:9)) | High | P0 | S | ★★★★★ |
| 5 | Decimal answers keep extra zeros or run to 20+ places | `100 * 1.25` → `125.00`, `2500 * 1.1` → `2,750.0`, `10000 * 1.05^10` → `16,288.94626777441406250000` | High | P0 | S | ★★★★★ |
| 6 | Escape doesn't close Quick Ganit, and it floats over other windows | Opened from the Window menu | Medium | P1 | S | ★★★★ |
| 7 | `total`, `count`, `min`, `max`, `h`, `m`, `s`, `g`, `t` can't be variable names, and the error doesn't say which word | `total = price * qty` → "Use words that are not units…", and every line below it fails too | High | P1 | S (better message) / M (allow names) | ★★★★ |
| 8 | Indian digit grouping breaks | `pmt(₹50,00,000, …)` → "wrong number of arguments"; `1,00,000 + 5,00,000` fails. No lakh grouping option | High (for Indian users) | P1 | M | ★★★★ |
| 9 | Can't show a ratio as a percentage | `savings / salary as %`, `in %` and `(x) as %` all fail | High | P1 | S | ★★★★ |
| 10 | `line N` points at a different line after you insert one above | Savings silently went from 4,449.51 to 7,484.51. This is documented behaviour, but still a trap | High | P1 | M (stable references, or a warning) | ★★★★ |
| 11 | Errors don't show where the problem is or how to fix it | "This part of the expression is unexpected" with no highlight; the popover shows the code `unexpectedToken`. The context menu also lists "Show Interpretation" twice | Medium | P1 | M | ★★★★ |
| 12 | Wrong or misleading error messages | `(5 V - 2 V) / 20 mA` → "Add a closing parenthesis"; `2 ** 10` → "Enter an expression here"; `(2 m)^0.5` → "exponent is too large" | Medium | P1 | S | ★★★★ |
| 13 | Dates like `16/09/2026` are silently divided | Gives 0.000877. That breaks the "never quietly guesses" promise | Medium | P1 | S (warn) | ★★★★ |
| 14 | `sin(30°)` fails even though `°` is a supported unit | "cannot combine these value types"; `sin(30)` is in radians and there's no degree mode | Medium | P1 | S | ★★★★ |
| 15 | One bad line breaks `sum` and `average` for the whole block | The budget total failed because of a currency error several lines up. No hint about which line | Medium | P2 | S (name the line) | ★★★ |
| 16 | Price × quantity with units fails | `0.15 USD/kWh * 45 kWh` and `₹8/kWh * 1,245 kWh` fail | High (household) | P2 | M | ★★★ |
| 17 | No electrical units | No V, A, Ω, F, H, mAh, dBm, hp or eV. `12 V * 2 A` fails, so the app doesn't work for electronics | High (for electronics users) | P2 | M | ★★★ |
| 18 | Travel units and mixed units missing | knot, nautical mile, L/100km, mpg, sq ft, `5 ft 10 in`, `2 h 30 min`, `3pm in Tokyo` | Medium | P2 | M | ★★★ |
| 19 | Mixed currencies don't convert automatically | `€40 + $10` errors, and `€40 + $10 in EUR` fails too | Medium | P2 | S | ★★★ |
| 20 | Large and tiny numbers never switch to scientific notation automatically | `1e100` prints 101 digits; `6.674e-11` prints as a long string of zeros | Medium | P2 | S | ★★★ |
| 21 | Spell-check underlines keywords | `sum`, `average` and `as` get red squiggles | Low | P2 | XS | ★★★ |
| 22 | Markdown Mode hides errors and misplaces answers | A failing line quietly turns into prose; the last answer drops onto the line below | Medium | P2 | M | ★★★ |
| 23 | Help has gaps | No list of supported units; "mortgage" finds nothing even though `pmt` exists; small window; empty results with no next step | Medium | P2 | S | ★★★ |
| 24 | Missing common functions and outputs | `mod`, `!`/factorial, `gcd`, `nCr`, `stdev`, `npv`/`irr`, `in hex`/`in binary`, `as fraction`, `<<`, `&`, `c` (speed of light), `√` | Medium | P3 | M | ★★★ |
| 25 | Variable names are case-sensitive, and brackets and `x²` don't work | `Monthly Rent` ≠ `monthly rent`; `Groceries (Costco) = 230` and `x²` fail | Medium | P3 | S | ★★ |
| 26 | Counted words aren't treated as labels | `412 pages`, `3 eggs * 4`, `85000 words / 250 words/min` fail; `85000 / 250 min` → `340 1/min` | Low | P3 | M | ★★ |
| 27 | "x ago" times in the sidebar go stale | A sheet stayed at "1 second ago" for minutes | Low | P3 | XS | ★★ |
| 28 | Empty "Untitled" sheets pile up | ⌘N keeps an empty sheet in the list for good | Low | P3 | XS | ★★ |
| 29 | Answers sit far from their lines in a wide window | About 1,300 px apart after Zoom on a large display. No maximum width and no row guides | Low | P3 | S | ★★ |
| 30 | Settings is sparse | No default decimals, locale or grouping, angle mode, or font; the shortcut is set elsewhere | Low | P3 | M | ★★ |
| 31 | Sheet search has no "No results" message and doesn't highlight matches | Searching `9,596` showed an empty list | Low | P4 | S | ★ |
| 32 | Inconsistent `≈` mark and a doc mismatch | `pmt(300000, …)` has no `≈` but the USD version does. The docs say `$` must be written as USD, yet `$20 * 3` works | Low | P4 | XS | ★ |
| 33 | The `ganit` command can't take assignments as arguments | `ganit "rent = 3"` → "character is not valid"; they work when piped in | Low | P4 | XS | ★ |

**How I ranked them:** The order weighs how badly and how often a problem bites (wrong answers first) against how much work the fix is (XS is under an hour, M is a few days). Rows 1–5 are all small fixes that stop wrong answers or broken-looking UI that most people will hit on day one. Rows 16–18 are the biggest gaps for particular groups (household bills, electronics, travel), but each needs new units added.

**Things that worked well:** date arithmetic (`Jan 31 + 1 month` → Feb 28), time zones by city, temperature conversions, `pmt`/`fv`/`pv` with currencies, big exact integers, long lines wrapping with the answer on the first row, and tab-separated Copy with Results.

Rows 1, 2, 4 and 7 are confirmed in the code; the rest are from what the app showed on screen. I didn't test global shortcuts, export or print, Services, Shortcuts, VoiceOver, or light mode.
