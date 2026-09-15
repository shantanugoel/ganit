# ADR 0006: Use ECB reference rates directly

- Status: Accepted
- Date: 2026-09-14
- Finalized: 2026-09-15 with the feed, format, and attribution below

## Context

Currency is Ganit's only planned automatic network feature. The provider must have authoritative provenance, a usable reuse policy, stable machine-readable data, and clear observation semantics. The European Central Bank publishes euro foreign exchange reference rates on working days, normally around 16:00 CET, for information rather than transaction settlement. ESCB statistics may be reused free of charge when the source is quoted and the statistics and metadata are not modified.

Third-party aggregators improve convenience but add an undisclosed authority and another availability, privacy, and schema dependency.

## Decision

- Download the ECB's official euro reference-rate feed directly over HTTPS with `URLSession`.
- Preserve the provider's decimal strings and observation date in an immutable snapshot. Derive cross rates from one snapshot using Ganit decimal arithmetic.
- Store provider identifier, source URL, observation date, retrieval instant, schema version, payload checksum, covered currencies, and validation result.
- Identify direct EUR rates as `ECB reference rate`. Identify cross rates as `Calculated by Ganit from ECB reference rates`; never present a derived cross rate as an unmodified ECB statistic.
- Display `Source: ECB statistics`, observation date, retrieval time, calculation method, stale/weekend status, and the indicative-not-for-transactions qualification in answer details.
- Never modify the downloaded provider snapshot. Derived Ganit values and metadata are stored separately.
- Support currencies outside ECB coverage only through explicit manual rates until another provider receives its own ADR.
- Do not use Frankfurter or another transport proxy.
- Allow only fixed ECB hosts; send no expression text, sheet identifiers, titles, device identifiers, or unnecessary locale headers.
- Reject unexpected status, redirects outside the allowlist, MIME type, oversized payloads, schema changes, duplicate codes, invalid decimals, implausible ranges, and regressing observation dates. A rejected response never replaces the atomic last-known-good snapshot.
- Retain the newest eight accepted provider snapshots, deduplicated by observation date and checksum, and remove older snapshots only after an atomic new snapshot is committed. Keep the compressed cache below 5 MB.
- Treat a snapshot as current on its observation date. On later dates, always show its age; label weekend carry-forward separately and mark it stale once its observation is more than four calendar days old. Provider details remain visible even when current.
- When automatic updates are enabled, request at most once after 16:15 Europe/Brussels on each local calendar day. Failed refreshes use exponential backoff capped at 24 hours, system scheduling, and no polling. A manual refresh may bypass the daily schedule but not an active request or a 60-second minimum interval.

### Feed and format

- The only endpoint is `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`,
  a GESMES envelope of about 2 KB whose single dated `Cube` element holds one
  `currency`/`rate` pair per covered currency, quoted as units per euro.
- The request is a plain `GET` with no cookies, query string, or custom
  headers beyond `Accept: text/xml`. Only `www.ecb.europa.eu` is allowed,
  including for redirects.
- Accept only `text/xml` or `application/xml` responses of at most 64 KB.

### Attribution

- `ThirdPartyNotices/CurrencyDataSources.md` records the source, feed, reuse
  terms, and information-only qualification, and ships in the app bundle.
- Answer details and the data sources notice quote the source as
  `Source: ECB statistics`.
- The ECB's qualification that reference rates are for information purposes
  only, and that using them for transactions is strongly discouraged, is shown
  with every currency answer as `Indicative, not for transactions`.

The Phase 0 build has no network entitlement or downloader. Networking is introduced only with the Phase 8 validator, cache, provenance UI, traffic audit, and attribution.

## Consequences

- Rates have first-party provenance and clear reuse terms.
- Coverage is narrower than commercial aggregators and updates stop on non-working days.
- Offline calculations work after one valid snapshot; missing currencies require a visible manual rate.
- Provider continuity is not assumed. Replacing or supplementing ECB requires a new ADR and cannot silently change historical provenance.

## References

- [ECB euro foreign exchange reference rates](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html)
- [Policy regarding reuse of ESCB statistics](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html)
