# ADR 0012: Ask a configured model about lines Ganit cannot work out

- Status: Accepted
- Date: 2026-09-16

## Context

Ganit's grammar and unit catalogue are finite, so some lines a person
reasonably writes — `10 kg of water in ml`, `how many pints in a firkin` — end
as a red diagnostic. A language model answers such lines well, but reaching one
means sending the line off the Mac, which ADR 0006 allowed only for the ECB
rate request and which the privacy statement promises does not happen.

The alternatives were to keep widening the built-in grammar, which cannot cover
open-ended questions; to ship a bundled model, which is hundreds of megabytes
for a calculator; or to let the reader choose a model and be told exactly what
is sent.

## Decision

- The assistant is off. It does nothing until someone fills in an address and
  a model under **Ganit ▸ Assistant…**, and turns it on.
- The address is any OpenAI-compatible base (`https://host/v1` and the like),
  so OpenAI, llama-swap, Ollama, a hosted proxy, and a model on this Mac are
  the same setting. Ganit POSTs `chat/completions` under that base. It ships
  no key, no default provider account, and no proxy of its own.
- HTTPS is required, except on the loopback address, where a local model
  answers without anything leaving the Mac.
- A request carries one line: the text of the line, the model name, and the
  instruction to answer with a value. It carries nothing else from the sheet,
  the library, or the machine, and `NetworkPrivacyTests` reads the bytes on the
  wire to keep that true.
- Ganit asks only about lines it flagged as ones it could not work out, once
  per line, and only after typing stops.
- The API key is kept in the keychain, not in preferences.
- An assistant's answer is drawn in its own colour, because a model's answer is
  a guess and a calculation is not.

## Consequences

- The privacy statement gains a second network request, and one that carries
  user text; it is a request nobody makes without asking for it.
- Ganit does not vouch for these answers, and its colour says so.
- Answers are not stored: they live as long as the sheet is open, and are asked
  for again afterwards.
- A provider that is not OpenAI-compatible needs a new decision, not a setting.
