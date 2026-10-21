# M-1 evidence — the Effort setting

Recorded 2026-10-21 on branch `ai` at the commit that adds it. This is the
milestone the plan had missed: [the plan](../../plans/ai-native.md) §9 calls it
**M-1**, and it lands before any Ask surface exists.

## What was built

| File | Work |
| --- | --- |
| `Sources/GanitData/AssistantEffort.swift` | the level: `off`, `low`, `medium`, `high`, `xhigh`, `max`, `custom(String)`; `wireValue`, `storageValue`, `init(storage:)`, `choices`, `default == .medium` |
| `Sources/GanitData/AssistantSettings.swift` | an `effort` field, preferences key `AssistantEffort`, default Medium |
| `Sources/GanitData/Assistant.swift` | one `reasoning_effort` word in the request; `strict`/`relaxed` request styles |
| `Sources/GanitWorkspaceUI/AssistantSettingsController.swift` | the Effort popup and the Custom field beside it |
| `App/Resources/Localizable.xcstrings` | ten `assistant.effort*` keys, and the Settings explanation rewritten to say what is sent |

## Decisions worth recording

- **Off omits the field** rather than sending `"none"`. A server that has never
  heard of `reasoning_effort` is likelier to accept the request when the field
  is absent, and someone who really wants the word `none` can type it under
  Custom… — which is what Custom… is for.
- **An empty Custom is Off.** The field can be left empty; that is the same
  preference as Off, and storing `custom:` would be a third state nobody can
  read back.
- **One preferences key** (`AssistantEffort`) holds both which level was chosen
  and, for Custom, the word: `custom:minimal`. An unrecognised level reads back
  as the default, so a level from a newer Ganit does not become a preference
  this one silently sends.
- **The relaxed retry drops both optional fields.** A server that does not
  implement `response_format` already refused the body and was asked again
  without it; a server that refuses `reasoning_effort` is in the same
  position, so the second ask now omits both. A refusal that outlives the
  relaxed ask is still reported, and Ganit asks twice at most.
- **Nothing in Ganit reads Effort.** It changes no timeout, no budget, no
  display, and no gate: it is a word for the server and nothing else.

## Checks that were run

Package suite: `swift test` — 1,160 tests in 10 runs, all passing, with
`./scripts/swift-format.sh lint` clean.

New tests (`Tests/GanitDataTests/AssistantTests.swift`):

- `sendsTheEffortItWasGiven(effort:word:)` — each level, and Custom, puts its
  word in the body.
- `sendsNoEffortPreferenceAtAll(effort:)` — Off and an empty Custom put no
  `reasoning_effort` in the body at all.
- `AssistantEffortTests` — default is Medium, every named level round-trips
  through preferences, `custom:` with nothing in it is Off, only the first word
  of a Custom is used, a 200-character Custom is truncated to 32.
- `keepsWhereToAskInPreferences` — Effort survives a write and a read.
- `aServerThatRefusesTheOptionalFieldsIsAskedAgainWithoutThem` — the first
  request names both fields and is refused, the second names neither and is
  answered.
- `aServerThatKeepsRefusingIsReported` / `aServerThatRefusesForAnotherReasonIsAskedOnce`
  — two asks at most, one ask when the body was fine.

`NetworkPrivacyTests.theAssistantBodyHoldsTheLineTheModelAndTheChosenEffortOnly`
names every key in the body: `model`, `messages`, `stream`, `response_format`,
`reasoning_effort` — and asserts both message contents.

Editor UI (`Tests/GanitWorkspaceUITests/SettingsControllerTests.swift`,
`AssistantSettingsEffortTests`): the popup offers the whole range and starts on
Medium, each named level is what Save reports, Custom enables the field and
sends what was typed, its leftover text is not a preference once a named level
returns, and a level saved as Custom comes back selected and filled.

## The running app, driven by the accessibility tree

`./scripts/build-app.sh debug`, then `open .build/app/debug/Ganit.app`.

1. **Ganit ▸ Assistant…** — the window shows `Effort [Medium ▾]` with a dimmed,
   uneditable field beside it, and the explanation now says the request carries
   the line, the model's name, and the Effort, and nothing else.
2. **The popup** lists exactly `Off · Low · Medium · High · Extra high · Max ·
   Custom…` with Medium ticked.
3. **Custom…** enables the field, focuses it, and shows the placeholder. Typing
   `minimal` and **Save** closes the window; reopening it shows `Custom…` with
   `minimal` in the field.
4. **On the wire.** With the address pointed at a loopback stand-in for an
   OpenAI-compatible server, **Try It** answered `10 kg of water in ml →
   10000 ml`, and the recorded request was:
   `{"model":…,"stream":false,"response_format":{"type":"json_object"},
   "reasoning_effort":"minimal","messages":[instruction, line]}` with
   `User-Agent: Ganit` and `Accept-Language: *` and nothing else.
   Choosing **Off** and asking again recorded the same body with no
   `reasoning_effort` key at all, while the Custom field still held the stale
   word `minimal` — which the popup correctly ignored.
5. **The automatic path** still works with the field present: with Effort back
   on Medium and the address restored, typing `10 kg of water in ml` into a
   sheet produced the purple `AI 10000 ml` answer after the usual pause.

The assistant's address, model and key were restored to what they were before
these checks, and Effort was left at the default Medium.
