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

The other is the assistant, and it is off. Nothing is sent until you fill in
an address and a model under **Ganit ▸ Assistant…** and turn it on. From then
on, a line Ganit could not work out — and only such a line, one at a time,
after you stop typing on it — is sent to the address you chose, with nothing
else: not the rest of the sheet, its title, or anything about your Mac. What
comes back is written in purple, because a model's answer is a guess and a
calculation is not. Your key is kept in the keychain. Pointing the address at
a model running on your Mac keeps even these lines at home.

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
