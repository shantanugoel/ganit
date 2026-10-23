# Ask verification record

Date: 2026-10-23.
Source baseline: `2c22018`, with the M5 changes in this branch.

## Test scope

Use a separate test app with the bundle ID
`com.shantanugoel.Ganit.AskM5FinalQA`. Use synthetic source and a provider on
`127.0.0.1`. Disable automatic exchange-rate downloads in the test app.
Do not use the saved user library or the configured user provider.

The test app has a separate library and preferences. Check that no provider
keychain item exists before the local provider test. Do not read a secret.
The user approved these computer-use tests on 2026-10-22.
For the final Context check, use `com.shantanugoel.Ganit.AskM5TakeoverFinal`.
The user approved AppleScript for this check on 2026-10-23.

## Checks

| Check | Evidence |
| --- | --- |
| Provider off | The Ask shortcut opens no bar. Calculate shows a disabled Ask command. The old three commands are absent. Ordinary calculations still show 12 and 36. The old function produces a normal diagnostic. |
| Settings | The text describes disclosed context. Review Example opens synthetic source and sends no request. The provider count remains zero. |
| Proposal | Context is available before Send. One explicit request returns checked results of 21 and 10. Excluding the second line changes the preview to 21. Apply changes source. Immediate Undo restores the original source. Redo restores the selected change. |
| Answer | A separate explicit request shows Paris in an unverified card. The card states that context was sent. It has no Apply action. Esc closes it. |
| Local explanation | The card shows the expression, result 220, grammar rule, and the statement that nothing was sent. The provider count does not change. |
| Clarification | The bar keeps the original instruction and offers answer buttons. It shows question one, then question two. A third question produces a failure with no Apply action. |
| Assumption | Apply writes one named density and an origin comment. The value has an AI badge. The result has a dependency dot. Editing density from 1 to 2 g/ml changes the result from 10,000 to 5,000 ml and removes the marks. The provider count does not change. |
| Native text input | The Option-E, E composition inserts an accented character in a comment. It does not send a request. |

The first desktop pass found two defects. A new Ask retained the previous
instruction. Interpretation cards were visible but absent from the exposed
text-view accessibility children. Regression tests cover both fixes.
The sheet also has explicit accessibility actions for an assumption and its
source. These actions supplement the labelled badge and dot controls.

The final desktop pass checked the proposal preview, line exclusion, Apply,
and exact source restoration with one Undo. It checked a new empty Ask,
a malformed reply, a temporary text answer, and a local explanation.
The provider count did not change for the local explanation. With the provider
off, the shortcut opened no bar and the Calculate menu disabled Ask.
The menu had no legacy assistant commands.

The final trace review found stale Context content after new words were typed.
Context now prepares the current instruction or typed clarification before it
shows the request. It sends nothing. Regression tests compare the prepared
body with the next transmitted body, including words with surrounding spaces.

The final release app passes the Context desktop recheck through AppleScript.
Context shows the current instruction and typed clarification. The loopback
request count stays at six during the first preview. Explicit Ask changes it
to seven. Partial Apply inserts only `3 * 7`. One Undo restores the exact
original comment. The next Ask gets a clarification and changes the count to
eight. Context shows the typed answer without changing that count. Explicit
Ask changes it to nine. The failure view has no Apply action. Source stays
unchanged. The isolated app is then closed and its provider is disabled.

The assumption source action opened the card through accessibility. Remove
showed the downstream diagnostic before any source change. Change value
selected the native value. A change from 1 to 2 g/ml removed the origin
comment and both marks. It changed the result from 10,000 to 5,000 ml.
One Undo restored the exact source and both marks.

The double-length string test found a clipped Repair attempts label.
Settings labels can now wrap. The same test passes after the repair.
The sidebar test now waits for layout. It checks the configured width limits
of 150 to 280 points. A saved width of 201 points is valid.

## Automated checks

The final full suite passes 1,367 tests with compiler warnings treated as
errors. The two Context tests check typed instructions, typed clarification
answers, zero requests before Send, and the exact transmitted bytes.

The double-length string layout test passes. The window-server capture test
passes in light and dark appearances. It checks that the Ask bar does not
cover the source. Formatting and whitespace checks pass.

Address Sanitizer passes the golden corpus, arithmetic property tests, and
10,000 Unicode fuzz inputs with seed `20261023`. All eight selected tests
pass. The release app builds with the native backend. Bundle verification,
signature verification, resource checks, and the bundled CLI calculation pass.

## Performance

The first release run failed the existing editor limits. The mixed fixture
had P95 latency of 27.683 ms against 16 ms. The dependency fixture had P95
latency of 185.815 ms against 50 ms. Keep these results as failed evidence.

The repairs keep provenance maps sparse, cache parsed origin comments, and
reduce numeric helper copies. Ordinary column mode avoids inline-gap scans.
A sheet with no table avoids a full text-attribute reset. Result updates keep
existing rows and remove old cache entries only when line identities change.
See the [measurement files](../../Benchmarks/Results/ai-native-m5-2026-10-22/).

The final checks use five independent processes for each fixture and mode.
Each process measures 200 edits. The gate uses the median of the five P95
values, as in the Phase 4 baseline. No edit samples are discarded.

| Fixture | Mode | Median P95 | Limit | Result |
| --- | --- | --- | --- | --- |
| Mixed sheet | No Ask | 10.496 ms | 16 ms | Pass |
| Dependency sheet | No Ask | 49.394 ms | 50 ms | Pass |
| Mixed sheet | Ask pending | 10.219 ms | 16 ms | Pass |
| Dependency sheet | Ask pending | 48.841 ms | 50 ms | Pass |

Every pending-Ask trial kept one injected request pending through all edits.
It then cancelled that request. These trials sent no network request.
They measure a pending provider. They do not measure candidate checking.

The native SwiftPM backend passes these checks on the pinned Xcode 27
toolchain. The default Swift Build backend has a dependency P95 median of
54.281 ms and fails the 50 ms limit. The backend comparison used the same source for both builds.
The release app, CI benchmarks, and benchmark commands now select the native
backend. Recheck backend support and latency before changing the toolchain.
The limits are unchanged.

The final repairs retain committed result arrays and index their lines.
Old immutable evaluations are released outside the UI thread. Reused parses
retain their kind maps. Numeric and temporal helpers copy fewer settings.
Integer construction and source assembly avoid temporary conversions.
A regression test checks resource limits after parse reuse and source edits.

See the [final measurements](../../Benchmarks/Results/ai-native-m5-2026-10-23/final-results.json).
The earlier failed measurements remain in the same directories.

Two individual dependency runs exceed 50 ms: 51.981 ms without Ask and
50.965 ms with Ask pending. The medians pass under the existing protocol.
These results have little margin. The baseline hardware check remains open.

## Coverage limits

The computer-use service could not start for the final Context check. It
reported `Sky Computer Use native pipe startup failed` after a runtime reset.
The approved AppleScript method completed this check in
`/tmp/GanitM5TakeoverFinal.app`. The app used synthetic preferences, a loopback
provider, and no automatic rate updates. A metadata-only check confirmed
that no provider keychain item exists. No secret was read.

The test Mac is an Apple M1 Max MacBook Pro with 32 GB of memory. It runs
macOS 27.0 and Xcode 27.0. These checks do not establish the release limits
on the 8 GB baseline Mac or the oldest supported macOS version.

Accessibility tests check labels, hierarchy, actions, focus, and announcements.
They do not establish the quality of VoiceOver speech. A person must listen
to that release check. Native accent composition does not replace a test
with a real CJK input method. These two manual release checks remain open.
