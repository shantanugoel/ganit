# Currency snapshots

Currency rates come only from the ECB daily reference-rate feed
([ADR 0006](../adr/0006-currency-provider.md)). Downloading, validation, and
storage are separate steps, so nothing reaches the cache until it has been
checked, and nothing replaces the cache until it is committed.

## Download

`RateDownloader` (GanitData) sends one fixed `GET` to
`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` with only an
`Accept: text/xml` header, over an ephemeral session with no cookies, cache, or
credential storage. Redirects to any other scheme or host are refused.

## Validation

`ECBRateValidator` accepts a response only when:

- the status is 200, the final URL is HTTPS on `www.ecb.europa.eu`, the MIME
  type is `text/xml` or `application/xml`, and the body is at most 64 KB;
- the body is a GESMES envelope with exactly one dated `Cube`;
- the observation date is a real `YYYY-MM-DD` date that is not in the future;
- every currency is a unique three-letter uppercase code other than `EUR`;
- every rate is a plain decimal string between 0.0001 and 1,000,000 units per
  euro;
- at least 20 currencies are present, including USD, JPY, GBP, and CHF.

The result is a `RateSnapshot`: the payload bytes, unmodified, and metadata
with the provider, source URL, observation date, retrieval time in whole
seconds, SHA-256 payload checksum, and the rates as published strings.

## Storage

`RateSnapshotStore` (GanitDocuments) keeps:

```text
Snapshots/<observation date>-<checksum prefix>/payload.xml
Snapshots/<observation date>-<checksum prefix>/metadata.json
LastKnownGood
```

A snapshot directory is written under a temporary name with durable atomic
file writes and renamed into place; it is never modified afterwards. The same
publication downloaded twice has the same ID and is stored once.
`LastKnownGood` names the accepted snapshot and is replaced atomically only
after the new directory is committed.

A commit is rejected, leaving `LastKnownGood` unchanged, when the payload no
longer matches its checksum, the observation date is not newer than the
last-known-good one, or any currency's rate more than doubles or halves
against it. Loading verifies the schema version, the ID, and the payload
checksum. After each commit, only the newest eight snapshots are kept, and the
last-known-good snapshot is never removed.

## Rollback

When the snapshot named by `LastKnownGood` fails to load — its payload no
longer matches its checksum, or a file is missing or unreadable —
`lastKnownGood()` falls back to the newest intact retained snapshot and names
it last-known-good. It fails only when no retained snapshot is intact.

## Refresh

`RateRefresher` (GanitDocuments) loads the last-known-good snapshot at launch
and publishes its rates to every open sheet and Quick Ganit. It follows
`RateRefreshPolicy` (GanitData):

- with no snapshot, a request is due at once;
- otherwise automatic requests happen at most once per local calendar day, no
  earlier than 16:15 in Brussels;
- a failed request — offline, rejected by validation, or refused by the
  store — is retried after 5 minutes, doubling up to 24 hours;
- **Calculate ▸ Update Exchange Rates** requests at once, unless a request is
  running or the last attempt was less than 60 seconds ago.

Each automatic request is one non-repeating `NSBackgroundActivityScheduler`
activity, so the system can defer it and nothing polls. Turning off
**Calculate ▸ Update Exchange Rates Automatically** cancels it; manual updates
still work. Accepted rates replace each open sheet's context and re-evaluate
it; a failed request leaves the last-known-good rates in use. The app has the
`com.apple.security.network.client` entitlement for this request only.

## Privacy verification

`NetworkPrivacyTests` sends the downloader's request through its real session
to a loopback server and checks the bytes on the wire: exactly
`GET /stats/eurofxref/eurofxref-daily.xml`, no body, only the `Host`,
`Accept`, `Accept-Language`, `Accept-Encoding`, `Connection`, and `User-Agent`
headers, `User-Agent: Ganit` and `Accept-Language: *` in place of the system
defaults that name the OS version and preferred languages, and no user name,
host name, OS version, or locale anywhere. The request is a constant, so it
cannot carry sheet text, titles, or identifiers. A source scan also fails if
any file other than `RateDownloader.swift` uses networking APIs, and the store
tests check that eight retained snapshots stay far below the 5 MB cache
budget.
