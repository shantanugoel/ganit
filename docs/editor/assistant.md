# The assistant

Some lines a person reasonably writes are not arithmetic Ganit knows how to do:
`10 kg of water in ml` needs to know what water weighs. Such a line ends as a
red diagnostic. The assistant is an optional second opinion for exactly those
lines, and nothing else. See [ADR 0012](../adr/0012-assistant-fallback.md) for
why it works this way.

## Setting one up

**Ganit ▸ Assistant…** holds four things: whether to ask at all, the address,
the model, and the key. The address is any OpenAI-compatible chat completions
endpoint, so these are both valid:

| Where the model runs | Address | Key |
|---|---|---|
| A provider | `https://api.openai.com/v1/chat/completions` | Required |
| This Mac | `http://localhost:11434/v1/chat/completions` | Not needed |

**Try It** asks the example line and shows the answer, or what went wrong, so a
wrong address or key is found here rather than in the middle of a sheet.
`AssistantSettings` keeps the address, model, and switch in preferences; the
key goes in the keychain, since preferences are a file any process running as
this user can read.

## What is asked, and when

`SheetEditorViewController` asks about a line when all of these hold:

- An assistant is set up and turned on.
- Ganit flagged the line as one it could not work out. A line that is merely
  half-typed is not flagged, so it is not asked about.
- Typing has stopped for `assistantPause`, which is 1.2 seconds.
- That exact text has not been asked about already. Answers are kept by the
  text that was asked, so the same line in two places costs one request, and
  editing a line and changing it back costs none.

**Ask Assistant** on the line's right-click menu, or under Calculate, asks
again about that line or prompt even when an answer is already on screen.

`SheetEditorViewController` also asks about `ask_assistant(prompt)` and
`prompt_assistant(prompt)` when those functions have no answer yet. The text
inside the parentheses is the prompt. The reply is parsed as a Ganit value,
so a later line can write `previous * 2`. The same pause, cache, and privacy
rules apply: one prompt is one request, and nothing else from the sheet is
sent.

`Assistant` sends one `POST` carrying the line, the model name, and the
instruction to answer with a value and nothing else. It sends nothing else from
the sheet, the library, or the machine, and `NetworkPrivacyTests` reads the
bytes on the wire to keep that true. HTTPS is required except on the loopback
address; redirects are refused, because a redirect would carry the line, and
the key, somewhere the settings never named.

A reply is used only if it is short enough to be an answer rather than an
explanation. `UNKNOWN`, an empty reply, and anything over 120 characters leave
the line as Ganit found it, and so does a failed request: a line Ganit could
not work out already says so, and needs no second complaint.

## What is shown

An answer arrives after Ganit has already written its own, so it replaces the
diagnostic in the answer column and is drawn in `VisualStyle.Color.assisted`,
purple, rather than the colour of a result. The line keeps its underline: Ganit
still could not read it. `AnswerCell.isAssisted` says which answers these are,
and they carry no full precision, because there is no exact value behind them.

Answers are not saved with the sheet. They live as long as the sheet is open.
