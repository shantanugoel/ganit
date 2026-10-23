# AI provider connections: implementation plan

Date: 2026-10-23
Status: Agreed scope. Implementation has not started.

Related plan: [Ask experience](ai-native.md).

## 1. Objective

Make AI connections easier to configure. Add provider presets and a model
list. Keep a Custom option for other endpoints. Improve parameter handling
and error messages without changes to the Ask calculation checks.

Use Foundation `URLSession`. Do not add an AI client library in this phase.
Keep the existing `SuggestionTransport` interface. Add a small provider
interface for connection defaults, authentication, and model discovery.

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
- If the error does not identify a field, permit one fallback that removes
  both optional fields, as the current code does.
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

1. Add provider identifiers, defaults, and settings migration.
2. Add the model discovery interface and provider response decoders.
3. Add bounded HTTP error decoding and separate parameter fallback.
4. Add the provider selector, model search, refresh, and manual entry controls.
5. Run focused tests and inspect the settings UI.

Reuse the existing Ask coordinator, request inspector, decoder, and engine
validation. Review a client library again when native generation APIs become
part of an agreed scope.

## 9. Acceptance checks

- Each preset produces the expected generation and discovery URLs.
- Existing settings load as Custom without a change to their values.
- Opening Settings sends no request.
- Model fetching sends no sheet content and does not consume an Ask request.
- Model lists handle extra fields, duplicates, pagination, and empty results.
- A late result cannot replace a list for a different connection.
- Manual model entry works without a successful model fetch.
- Parameter fallback removes the identified field and preserves the other.
- An unclear parameter error permits only the bounded fallback described above.
- Fallback attempts remain within the existing request and time limits.
- Error messages do not expose credentials.
- Existing request inspection and calculation validation checks still pass.
- The settings UI supports keyboard use and provides accessible control names.

Use fixture responses and a local test server for automated checks. Record
live provider checks separately when credentials and network access are
available. Do not report fixture checks as proof of live provider support.
