# Sandbox, input, and provenance audit

Audit of PLAN §10 as of 2026-09-15 (commit after `49fb9bc`). Each row names
the check that keeps it true.

## Sandbox and signing

| Item | State | Enforced by |
| --- | --- | --- |
| App Sandbox | On | `scripts/verify-app.sh` compares signed entitlements |
| Entitlements | `app-sandbox`, `files.user-selected.read-write`, `network.client` only | Same exact comparison |
| Network client | Used only for the ECB rate request and, when it is set up, the assistant | `onlyTheRateDownloaderUsesTheNetwork` source scan |
| Hardened Runtime | On for the app and `Contents/Helpers/ganit` | `build-app.sh` signs with `--options runtime`; `verify-app.sh` checks the flag |
| Embedded frameworks | None | `verify-app.sh` |
| Privacy manifest | No collected data, no tracking | `verify-app.sh` compares `PrivacyInfo.xcprivacy` |
| Logging | App modules never log | `appModulesDoNotLog` source scan; signposts carry static names only |

## Input surfaces

Every way data enters Ganit from outside its own library is bounded.

| Surface | Limit | Enforced by |
| --- | --- | --- |
| Evaluate Expression service | 4 KB expression; reads only the pasteboard it is handed | `ExpressionCalculationTests`, `ExpressionServiceTests` |
| Calculate Expression intent | 4 KB expression; does not open the app | `CalculateExpressionIntentTests`, `verify-app.sh` |
| `ganit://` URL | 8 KB URL, 4 KB expression, one action, allowlisted parameters, no `ganit:`/`file:` callbacks | `CalculationCallbackTests` |
| `ganit` command | 4 KB expression argument, 1 MB UTF-8 sheet on standard input | CI command-line step |
| Import (`.ganit`, text) | 1 MB source, 64 KB manifest, UTF-8 only, known schema only | `SheetExchangeTests` |
| Exchange-rate download | Fixed HTTPS host, 64 KB, strict schema, plausible ranges | `ECBRateValidatorTests`, `NetworkPrivacyTests` |
| Assistant request | Off until set up; HTTPS or this Mac only, no redirects, one line of at most 500 characters, 64 KB reply | `AssistantTests`, `NetworkPrivacyTests` |
| Editor text | Engine limits: 1 MB source, 100,000 tokens, parse depth 128 | Engine limit tests, fuzzing |

URL, service, intent, and command-line requests only compute an answer: none
reads or writes sheets, the Quick Ganit buffer, or the clipboard, so none needs
foreground confirmation. The only pasteboard writes are Copy Result, Copy Full
Precision, and ⌘Return in Quick Ganit, all explicit commands.

## Data provenance

| Data | Provenance | Where visible |
| --- | --- | --- |
| Exchange rates | ECB payload stored byte for byte with SHA-256 checksum, observation date, retrieval time | Answer details; `docs/storage/currency-snapshots.md` |
| Cross rates | Marked as calculated by Ganit from ECB reference rates | Answer details |
| Manual rates | Declared in the sheet, marked as manual | Answer details |
| Units | Independently encoded from cited sources | `ThirdPartyNotices/UnitSources.md`, generated and verified in CI |
| Time zones | System IANA database; resolved zone and offset shown | Answer details |
| Finance assumptions | Stated per function | Answer details |

## Findings

- Import read files without a size limit; a very large file would have been
  read into memory. Fixed: imports are bounded at the engine's 1 MB source
  limit and 64 KB for a package manifest.
- No other unbounded external input, logging of user content, or undeclared
  entitlement was found.
