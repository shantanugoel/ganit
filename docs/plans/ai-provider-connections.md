# AI provider connections: implementation plan

Date: 2026-10-23
Status: Implemented. See the verification record in section 10.

Related plan: [Ask experience](ai-native.md).

## 1. Objective

Make AI connections easier to configure. Add provider presets and a model
list. Keep a Custom option for other endpoints. Improve parameter handling
and error messages without changes to the Ask calculation checks.

Use Foundation `URLSession`. Do not add an AI client library in this phase.
Keep the existing `SuggestionTransport` interface. Add a small provider
interface for connection defaults, authentication, and model discovery.

This phase uses one generation API and model-list requests. The existing
transport controls request inspection, response-size limits, redirects,
cancellation, and request limits. An AI client library can supply request
types and response decoders. Ganit must still enforce these controls and its
calculation checks. Keep the current transport to limit changes in this phase.

## 2. Scope

Add these provider choices:

| Provider | Connection setup |
| --- | --- |
| OpenAI | Supply the hosted endpoint and Bearer authentication defaults. |
| OpenRouter | Supply the hosted endpoint and Bearer authentication defaults. |
| Ollama | Supply the local server defaults. Permit address changes. |
| LM Studio | Supply the local server defaults. Permit address changes. |
| Custom | Permit endpoint, key, and model entry. |

Keep Chat Completions as the request API. Model discovery must use the
selected provider's model-list API. It does not require support for the
provider's other generation APIs.

Do not add these features in this phase:

- Tool calls or tool execution.
- Streaming.
- Responses API, Anthropic Messages, or native Gemini generation APIs.
- External model catalogs, prices, context limits, or capability databases.
- Changes to request time limits or the full job deadline.
- Changes to the existing network address and redirect policies.
- Multiple saved connection profiles or automatic provider selection.

A model-list entry does not prove that the model supports Chat Completions
or the Ganit reply format. Show this limit clearly when a request fails.

## 3. Settings behavior

1. Let the user select a provider.
2. Fill in its connection defaults. Show the address before any request.
3. Let the user enter a key where required.
4. Provide a Fetch Models action. Provide Refresh after a successful fetch.
5. Show a searchable model list. Store the selected model identifier.
6. Keep manual model entry available at all times.

Clear the key in the settings form when the provider or endpoint origin
changes. The origin consists of the scheme, host, and effective port. A change
to the path alone does not change the origin. Require key entry again where
authentication is required. Do not copy a previous provider's key to the new
connection. Do not change the saved key until the user saves the settings.

Opening Settings, selecting a provider, or entering a key must not start a
network request. Fetch Models and Refresh send only the discovery request.
They must not send sheet content or start an Ask job.

Show loading, empty-list, and failure states. Permit cancellation. If model
discovery fails, preserve the current model and permit manual entry. Do not
require discovery before an Ask request.

Discard a discovery result if the user changes the provider, endpoint, or
credentials before the result arrives. A failure must not erase a previously
selected model. Do not silently replace a model when the list changes.

## 4. Provider and discovery code

Define a provider identifier and connection defaults in `GanitData`. Keep
provider-specific URL and authentication rules in this layer. Keep these rules
out of the settings view controller.

Use these connection defaults and model-list URLs:

| Provider | Default API base | Model-list URL at the default address | Authentication |
| --- | --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `https://api.openai.com/v1/models` | Bearer key required. |
| OpenRouter | `https://openrouter.ai/api/v1` | `https://openrouter.ai/api/v1/models/user` | Bearer key required. |
| Ollama | `http://localhost:11434/v1` | `http://localhost:11434/v1/models` | The local server does not require a key. |
| LM Studio | `http://localhost:1234/v1` | `http://localhost:1234/v1/models` | Bearer token if server authentication is enabled. |
| Custom | User-supplied API base or full Chat Completions URL | `/models` below the API base | Send a Bearer key only if the user supplies one. |

Apply the authentication rule to generation and discovery. Keep optional key
entry available for local connections. Send a supplied key as a Bearer key.
Do not insert a placeholder key when the key is empty.

Append `/chat/completions` to the API base for generation. For discovery,
append `/models` to the selected API base. Use `/models/user` for OpenRouter.
Preserve the existing path prefix of the API base.

For Custom, accept the same endpoint forms as the existing generation code.
If the endpoint has a final `/chat/completions` path, remove that suffix to
find the API base for discovery. A host-only endpoint uses `/v1` as the API
base path. Ignore a final slash when constructing these paths. Preserve any
other path prefix. Thus, `https://host/prefix/v1` and
`https://host/prefix/v1/chat/completions` both produce
`https://host/prefix/v1/models`. Do not change the stored endpoint during
discovery. If the endpoint does not support this model-list path, report the
failure and keep manual model entry available.

Use the OpenRouter user-filtered model list. Do not substitute its full
catalog. This list applies user provider preferences, privacy settings, and
guardrails. It does not prove that a generation request will succeed.

Define a model-list item with an identifier and an optional display name.
Do not require capability or price fields. Accept additional response fields
without using them. Remove duplicate identifiers from the displayed list.

Use the selected endpoint and credentials for discovery. Do not fetch a
global catalog as a substitute for the endpoint's model list. Support model-list
pagination where the selected API requires it. Set response-size limits and
apply the existing network address and redirect policies to discovery.

Keep discovery separate from `SuggestionTransport`. Discovery must not use
the Ask request budget. Do not make hidden generation requests to test a
connection or infer model capabilities.

## 5. Request compatibility

Continue to send a system message, a user message, and a non-streaming Chat
Completions request. Continue to require one reply with a JSON object in
`message.content`. Do not extract proposals from reasoning fields or tool calls.

Handle `response_format` and `reasoning_effort` separately:

- If an HTTP 400 or 422 error identifies one of these fields as unsupported
  or invalid, remove only that field for the next attempt.
- Preserve the other field and the rest of the request.
- Check recognized error codes and categories before applying a fallback.
  Do not remove optional fields for a known unrelated failure, even if the
  error does not identify a field. Examples include a context-limit failure,
  an unavailable model, or an authentication failure.
- For an HTTP 400 or 422 error with an unknown cause and no identified field,
  permit one fallback that removes both optional fields.
- Remove a field only if it was present in the rejected request. Do not
  retry if the fallback cannot change the request body.
- Do not repeat an attempt with the same parameter settings after rejection.
- Count each attempt against the existing limit of three requests per job.
- Keep the existing limits for repair attempts and job duration.

Apply these changes within the current job. Do not add a persistent model
capability cache in this phase. Show the exact request body for each attempt
through the existing Context inspection path.

## 6. Error handling

Read a bounded error body before reporting an unsuccessful HTTP status.
Retain the status and structured error code or parameter where supplied.
Use this information for parameter fallback and useful user messages.

Check bounded HTTP 200 response bodies for provider errors before decoding
reply content. In particular, OpenRouter can return an error object without
`choices`, or a choice with an error and partial content. Check errors at the
response and choice levels, including `finish_reason: "error"`. Retain the
HTTP status and the provider error code or category as separate values.
Do not accept partial content from a failed generation. Do not classify a
provider error as an invalid reply or start a schema repair request for it.
Apply the fallback rules in section 5 only to eligible parameter errors.

Pass the error category through the Ask coordinator to the user message.
Do not replace a known authentication, model, or server error with a general
connection failure.

Distinguish these cases where the response provides sufficient information:

- Invalid or missing credentials.
- Unknown or unavailable model.
- Unsupported or invalid request parameter.
- Rate limit.
- Server failure.
- Invalid reply format.
- Model discovery failure.

Use a general message when the cause is unknown. Do not display credentials,
request headers, or an unfiltered server error body. Do not add automatic
retries for rate limits or server failures in this phase.

## 7. Existing settings

Treat settings with no stored provider identifier as a Custom connection.
Preserve the endpoint, key, model, effort, enabled state, repair limit, and
answer marking preference. Do not infer a preset from the stored host name.

Keep keys in Keychain. Do not store keys in model-list data or preferences.
Use an explicit settings version if migration requires one. A failed fetch
must not change stored connection settings.

## 8. Implementation sequence

1. Add provider identifiers, defaults, settings migration, and key clearing.
2. Add the discovery interface, URL rules, authentication, and response decoders.
3. Add bounded provider error decoding, error reporting, and parameter fallback.
4. Add the provider selector, model search, refresh, and manual entry controls.
5. Run focused tests and inspect the settings UI.

Reuse the existing Ask coordinator, request inspector, decoder, and engine
validation. Review a client library again when native generation APIs become
part of an agreed scope, or when the amount of provider-specific code makes
the current approach more difficult to maintain. Compare the code removed
with the code needed to preserve the existing transport controls.

## 9. Acceptance checks

- Each preset produces the expected generation and discovery URLs.
- Custom discovery preserves path prefixes and accepts full Chat Completions
  URLs, API bases, and host-only endpoints.
- OpenRouter discovery uses `/api/v1/models/user` at the default endpoint.
- Discovery and generation apply the same authentication rules. LM Studio
  accepts an optional token, and local connections work without a key.
- Existing settings load as Custom without a change to their values.
- A provider or endpoint-origin change clears the key in the settings form.
  Neither discovery nor generation sends the previous key to the new connection.
- A path-only change keeps the key. Unsaved edits do not change the saved key.
- Opening Settings sends no request.
- Model fetching sends no sheet content and does not consume an Ask request.
- Model lists handle extra fields, duplicates, pagination, and empty results.
- A late result cannot replace a list for a different connection.
- Manual model entry works without a successful model fetch.
- Parameter fallback removes the identified field and preserves the other.
- Known unrelated errors do not trigger parameter fallback, including errors
  with a recognized code but no identified field.
- An unclear parameter error permits only the bounded fallback described above.
- Fallback does not retry removal of a field that was absent from the request.
- Fallback attempts remain within the existing request and time limits.
- HTTP 200 provider errors, including errors with partial content, produce
  no proposal and no schema repair request.
- Known provider error categories reach the user message without replacement
  by a general connection failure.
- Error messages do not expose credentials.
- Existing request inspection and calculation validation checks still pass.
- The settings UI supports keyboard use and provides accessible control names.

Use fixture responses and a local test server for automated checks. Record
live provider checks separately when credentials and network access are
available. Do not report fixture checks as proof of live provider support.

## 10. Verification record

Date: 2026-10-23. Platform: Apple silicon Mac. Toolchain: Xcode 27.0,
Swift 6.4. Tests use fixtures and local servers.

The implementation adds no package dependency. Existing settings load as
Custom. Key storage remains in Keychain. Discovery uses a separate interface
and shares the generation transport's address and redirect rules. Discovery
limits are 2 MiB per page, 8 MiB in total, 32 pages, and 10,000 unique model
identifiers. It does not follow a server-supplied page URL.

Review covered URL construction, key clearing, late results, request limits,
provider errors, reply validation, localization, and keyboard access. The
review found and corrected a full generation URL path issue, short text-field
frames, an invalid-address fallback, a stale address message, and loss of a
provider error category at the request limit.

| Check | Result |
| --- | --- |
| `swift package dump-package` | Passed. |
| `swift test --parallel -Xswiftc -warnings-as-errors` | Passed: 1,399 tests across 11 test targets. |
| `GANIT_PSEUDOLOCALIZATION=1 swift test -Xswiftc -warnings-as-errors --filter PseudolocalizationTests` | Passed: double-length text fits. |
| `swift build -Xswiftc -warnings-as-errors` | Passed for all package products. |
| `./scripts/swift-format.sh lint` | Passed. |
| `./scripts/build-app.sh debug` | Passed. The app launched. |
| `./scripts/verify-app.sh .build/app/debug/Ganit.app` | Passed. |
| `git diff --check` | Passed. |
| Command-line smoke checks | Passed: `20% off 85` gives `68`; `rent = 3` and `rent * 12` give `3` and `36`. |

Manual UI checks used a local model-list server. Fetch Models loaded two
fixture models. Search reduced the list to one model. Tab and Down selected
that model. The server received one GET request for `/v1/models`. The settings
window was closed without a save. The final app build was inspected again
after the text-field height fix. The address, model, and key fields show
their full text height.

Live provider requests were not run. These checks do not establish live
provider support.

## 11. References

- [OpenAI SDKs and HTTP clients](https://developers.openai.com/api/docs/libraries).
- [MacPaw Swift client](https://github.com/MacPaw/OpenAI).
- [OpenRouter user-filtered model list](https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails).
- [OpenRouter error handling](https://openrouter.ai/docs/api_reference/errors-and-debugging).
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility).
- [LM Studio model list](https://lmstudio.ai/docs/developer/openai-compat/models).
- [LM Studio authentication](https://lmstudio.ai/docs/developer/core/authentication).
