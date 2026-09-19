# The assistant

Some lines a person reasonably writes are not arithmetic Ganit knows how to do:
`10 kg of water in ml` needs to know what water weighs. Such a line ends as a
red diagnostic. The assistant is an optional second opinion for exactly those
lines, and nothing else. See [ADR 0012](../adr/0012-assistant-fallback.md) for
why it works this way.

## Setting one up

**Ganit ▸ Assistant…** holds four things: whether to ask at all, the address,
the model, and the key. The address is any OpenAI-compatible **base**, so
these are all valid:

| Where the model runs | Address | Key |
|---|---|---|
| A provider | `https://api.openai.com/v1` | Required |
| This Mac | `http://localhost:11434/v1` | Not needed |
| Another host | `https://host/v1` | As that host asks |

Ganit POSTs `chat/completions` under the base, so `https://host/v1` and
`https://host/v1/chat/completions` are the same setting. A `/v1` base is
what the OpenAI SDK, llama-swap, Ollama, and other compatible servers
publish; posting to that path without `chat/completions` is a 404. A host
with no path is treated as `/v1` too. HTTP is only for this Mac; everything
else is HTTPS.

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
  editing a line and changing it back costs none. `AssistantAnswerStore`
  keeps each reply, including "no answer", in `AssistantAnswers.json` under
  Application Support, so reopening a sheet or relaunching Ganit does not ask
  again. A failed or cancelled request is not kept.

**Ask Assistant** on the line's right-click menu, or under Calculate, asks
again about that line or prompt even when an answer is already on screen or
kept, and keeps the new reply instead.
**Change Answer…** offers **Save Value into Sheet** and **Use Temporarily**.
Saving validates a single-line value Ganit can calculate without assistance,
replaces the selected line with it, and retains the original source as a
`// Manual answer; original:` comment. The value survives restart as sheet
source and can be used by later formulas. Undo restores the original line.
Using a correction temporarily replaces the displayed value without a request;
the dialog explains that temporary corrections are discarded when Ganit quits.

**Cancel Request** on the same menus stops waiting for a line or prompt that
shows Asking…, and **Calculate ▸ Stop** cancels every request of the sheet as
well as its evaluation. Each request is a task the editor keeps, so a
cancelled request's late reply is ignored, and a cancelled line or prompt is
not asked about again until Ask Assistant. Cancelling cannot recall a line
already sent, or make the provider stop working on it; it only means Ganit no
longer waits for or uses the reply.

`SheetEditorViewController` also asks about `ask_assistant(prompt)` when it
has no answer yet. The text inside the parentheses is the prompt, except that
a `{…}` placeholder holds an expression, such as `{weight}` or `{previous}`,
whose value is written into the prompt as the sheet shows it. Typing `{`
offers the sheet's variables, and choosing one closes the placeholder. The reply is
parsed as a Ganit value, so a later line can write `previous * 2`. Answers are
kept by the prompt with its placeholders' values, so changing `weight` asks
again and changing it back costs nothing. A placeholder Ganit cannot work out
fails the line and nothing is sent. The same pause and privacy rules apply:
one prompt is one request, and nothing else from the sheet is sent than the
values its placeholders name.

`Assistant` sends one `POST` carrying the line, the model name, and the
instruction to reply with `{"value":"…"}`. It sends nothing else from the
sheet, the library, or the machine, and `NetworkPrivacyTests` reads the bytes
on the wire to keep that true. HTTPS is required except on the loopback
address; redirects are refused, because a redirect would carry the line, and
the key, somewhere the settings never named. A host that rejects structured
output is asked again without it. The request may take a few minutes; the
sheet stays editable.

`AssistantReply` then takes the short value out of JSON, think-tags,
markdown, and wrapping. A model's separate reasoning is its working, so it is
read only for that JSON value, never for a last sentence. `UNKNOWN`, an empty
reply, a reply with no letter or digit, and anything still over 120 characters
leave the line as Ganit found it, and so does a failed
request: a line Ganit could not work out already says so, and needs no
second complaint.

## What is shown

While a request is in flight the answer column shows Asking… in secondary
colour, not the red diagnostic. An answer replaces that and is drawn in
`VisualStyle.Color.assisted`, purple, rather than the colour of a result, after
an outlined **AI** badge, so its origin does not depend on seeing colour or
survive only in colour on a screenshot. Hovering it says it is an unverified AI
answer formulas cannot use, and VoiceOver reads it as `Line N AI answer,
unverified`. The
line keeps its underline: Ganit still could not read it. `AnswerCell.isAssisted`
says which answers these are, and they carry no full precision, because there
is no exact value behind them.

A line-level answer is a display answer only: the engine still cannot read the
line, so `line N`, `previous`, and totals cannot use it. A line referring to
one says `Line N has an AI display answer, which formulas cannot use`, rather
than the general reference error, and the answer's interpretation card shows
the AI answer and that **Change Answer… ▸ Save Value into Sheet** turns a
reviewed value into source later lines can use. `ask_assistant(prompt)` is the
computable path: its parsed value takes part in later arithmetic.

Model answers and temporary corrections are not saved with the sheet. They
remain in the open sheet's session cache, including after closing and reopening
its tab, but are discarded when Ganit quits. A correction explicitly saved into
sheet source is durable.
