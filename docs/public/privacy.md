# Privacy

Ganit is a calculator that keeps your calculations on your Mac.

## What Ganit collects

Nothing. Ganit has no account, analytics, crash upload, advertising, remote
configuration, or tracking. Its privacy manifest declares no collected data
and no tracking.

## What stays on your Mac

Your sheets, Quick Ganit text, definitions, backups, and preferences are
stored only in Ganit's sandbox container. Ganit writes no logs of your
calculations. Nothing is synced.

## The network requests Ganit makes

To convert currencies, Ganit downloads the European Central Bank's public
euro reference rates, at most once a day plus when you choose **Calculate ▸
Update Exchange Rates**. The request is a fixed address with no calculation,
sheet, title, account, device, language, or operating-system details. You can
turn automatic updates off with **Calculate ▸ Update Exchange Rates
Automatically**; conversions then use the last rates Ganit accepted or rates
you declare.

The second is Ask Ganit. It is off until you configure and enable a model
under **Ganit ▸ Assistant…**. Opening Ask or typing in a sheet sends nothing.
A request starts only after an explicit send action: Return, Ask, Answer,
Retry, or a clarification choice. Opening Context sends nothing.

Settings also has **Fetch Models** and **Refresh**. These actions send only
a model-list request to the address shown in Settings. The request includes
a supplied key and no sheet content. Opening Settings, selecting a provider,
or entering a key sends no request. A fetch does not require Ask to be on.

**Context ▸** shows the source and exact request body before Send. The request
includes the target lines, relevant values, transitive source dependencies,
attached notes, captured function inputs, diagnostics, engine settings, and
the function catalog. Engine settings include the sheet locale, time zone,
and frozen calculation time. These are calculation inputs, not a system
profile. The target is limited to 12 contiguous lines and 8 KiB and cannot
include a table block. Unrelated source, sheet titles, library contents, and
local document identifiers are excluded. Opaque handles identify records.

The request also includes your instruction, the model name, the selected
Effort, and instructions for the model. Off omits the Effort field. A job can
make up to three requests for format fallback, additional context, or repair.
Additional context requires review before Send. Replies are held in memory;
Ganit does not save a provider reply cache. Applied source changes and
approved assumptions are saved as ordinary sheet source. Assumptions carry
an AI origin comment.

The endpoint you choose receives this content and the key needed to access
it. Your key is stored in the keychain. Ganit uses an ephemeral network
session without cookies or a persistent cache. It refuses redirects. HTTPS
is required except for loopback addresses. A loopback provider can keep the
request on your Mac; that provider controls any further network use.

The third is the update check, and it is also off. A fresh copy of Ganit never
asks GitHub whether a newer version exists; choosing **Ganit ▸ Check for
Updates…** asks once, and ticking **Check for Updates Automatically** asks
once a day from then on. The request fetches a fixed file listing the latest
release. Ganit sends no identifier with it and no system profile, and an
update installs only if it is signed both by Ganit's Developer ID certificate
and by Ganit's update key.

## Spotlight, services, and other apps

- **Spotlight** is off by default. When you turn on **Show Sheet Titles in
  Spotlight**, only sheet titles are indexed on your Mac.
- The **Evaluate Expression** service, **Calculate Expression** shortcut,
  `ganit://` links, and `ganit` command answer the expression they are given
  and read nothing else.
- **Report a Problem** saves a report on your Mac for you to send. It includes
  a sheet's text only if you tick the box.

## Details

The [security audit](../security/audit.md) lists every input Ganit accepts and
the tests that keep these statements true.
