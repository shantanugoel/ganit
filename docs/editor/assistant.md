# Ask Ganit

Ask Ganit is optional. Ganit calculates each result with its own engine.
A model can propose source changes or explain intent. It cannot supply a
calculated answer in the answer column. See
[ADR 0019](../adr/0019-ask-one-operation-four-outcomes.md).

## Configure a model

Open **Ganit ▸ Assistant…**. Select a provider and check its address.
Enter a key if required. Enable Ask and enter a model identifier.

| Provider | Default API base | Key |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | Required |
| OpenRouter | `https://openrouter.ai/api/v1` | Required |
| Ollama | `http://localhost:11434/v1` | Optional |
| LM Studio | `http://localhost:1234/v1` | Required if server authentication is on |
| Custom | Your API base or full Chat Completions URL | As the server requires |

Select **Fetch Models** to get models from the selected address. Use the
search field to find a model. Select a row to use its identifier. **Refresh**
gets the list again. **Cancel** stops a pending fetch. A fetch sends no sheet
content and uses no Ask request. Opening Settings sends no request.

You can enter a model identifier at any time. A failed fetch does not remove
it. A model list does not confirm support for Chat Completions or the Ganit
reply format. OpenRouter uses the list for your account preferences and
privacy settings at `/models/user`.

A provider or endpoint-origin change clears the key in the form. The origin
is the scheme, host, and effective port. A path-only change keeps the key.
The saved key changes only when you select **Save**. Settings without a
stored provider load as Custom and keep their values.

Ganit appends `chat/completions` to the base. A complete
`/v1/chat/completions` address is also valid. An address with no path uses
`/v1`. HTTP is permitted only for a loopback address. Other addresses require
HTTPS. Ganit refuses redirects.

**Review Example** opens a local test sheet. It sends nothing until you
review Context and send an Ask from that sheet.

Preferences store the provider, endpoint, model, enabled state, Effort,
repair limit, response timeout, and dependency mark setting. The key is
stored in the keychain.

**Effort** requests a reasoning level from the server. The default is Medium.
Off omits `reasoning_effort`. Low, Medium, High, Extra high, and Max send
`low`, `medium`, `high`, `xhigh`, and `max`. Custom sends the text you enter.
An empty Custom value omits the field. The server controls its effect.

**Repair attempts** permits zero to three corrections of a rejected reply.
The default is two. Each Ask permits at most three requests in total.
Format fallback and context follow-ups use this same request limit.

**Response timeout** sets the seconds one Ask waits for its reply. The
default is 120, and the field accepts 5 to 600. A model that thinks before it
answers is slow on this Mac and on a hosted address alike, so one number
covers both. The job that owns an Ask gets three of these waits, one for each
request it may make. A change applies to the next Ask; a request already sent
keeps the number it started with.

If an HTTP 400 or 422 error identifies `response_format` or
`reasoning_effort` as invalid or unsupported, Ganit removes only that field
for the next request. An unknown error with no identified field permits one
fallback without both fields. Known credential, model, context, rate-limit,
and server errors do not start this fallback. Provider errors do not start
reply repair. Ganit does not accept partial content from a failed request.

## Open and send Ask

Press **⌘⇧A**, or choose **Calculate ▸ Ask Ganit…**. The same action is
available in the selection summary, the right-click menu, and the Ask chip
beside the current line when Ganit cannot read it. These actions open the
same bar. They do not send a request.

Enter your instruction. Open **Context ▸** to inspect the source and the
exact request body. To send, press Return or select Ask. Answer and Retry
also send requests. Selecting a clarification choice sends that answer.
Opening Ask or Context sends nothing. Ganit sends no automatic requests
when you type or stop typing. Escape cancels Ask. Cancellation cannot recall
bytes that have already reached the provider.

The target is the current line, selection, or sheet. A target must be
contiguous, contain at most 12 lines and 8 KiB, and exclude table blocks.
Context includes the target, attached notes, relevant named values,
transitive source dependencies, captured function inputs, diagnostics,
engine settings, and the supported function catalog. Engine settings include
the sheet locale, time zone, and frozen calculation time. These are disclosed
calculation inputs. They are not an automatic report about the Mac.

Unrelated source, sheet titles, library contents, and local document
identifiers are excluded. Opaque handles identify source records in the
request. A request for more context requires a new review of Context before
Send. See [privacy](../public/privacy.md).

## Review the result

- **Proposal:** Ganit checks the proposed source on a frozen sheet copy.
  Review each source change and calculated result. Use the inclusion controls
  to select changes. Ganit checks the selected source again. Invalid source
  has no preview and cannot be applied. Choose **Apply** or press **⌘↩** to
  change source in one Undo step named **Apply AI Change**. Undo restores the
  original source and selection. Later input edits calculate locally.
- **Question:** Answer in the same Ask bar. Ganit asks at most two questions
  per Ask. It asks for inputs that only you can supply, such as a tax rate,
  salary, price, or budget.
- **Assumption:** A missing world fact can become a named value on its own
  line. Ganit writes a `// AI:` origin comment after approval. The AI badge
  identifies the value. A dot identifies dependent results. **View ▸ Mark
  AI-derived answers** controls the dots. The origin badge remains visible.
  Open the badge to inspect the basis, model, date, and dependent lines.
  Change the value to remove its origin mark. Removal previews affected
  calculations before it changes source.
- **Explanation:** Ganit first explains the expression with local engine
  facts. The card states whether anything was sent. **Ask the model instead**
  opens Ask and waits for Send. A model explanation is marked as such. Cards
  are temporary, cannot be referenced by formulas, and are not saved.
- **Answer:** A text answer can address a question with no calculation. It
  is marked as unverified, is not saved or cached, and cannot be referenced
  by formulas. It cannot contain numeric characters, arithmetic operators,
  equations, or source. A needed fact for a calculation must become a named
  assumption.
- **Failure:** Ganit shows the reason. A rejected reply has no Apply action.
  **Show what the model meant** opens rejected text in a separate read-only
  view. Retry starts a new explicit Ask.

Ganit asks when only you know; it assumes and marks when the world knows.
If the choice is uncertain, Ganit asks.

Ask uses a bounded memory cache. It does not save provider replies in
`AssistantAnswers.json`. Existing files are not read. The former
`ask_assistant(...)` syntax and prompt placeholders are not supported.
Use ordinary source and Ask proposals instead. Ask is unavailable in Quick
Ganit, services, shortcuts, and the command-line tool.
