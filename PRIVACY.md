# awmouse — Privacy Policy

_Last updated: 2026-09-15_

awmouse turns your iPhone into a remote mouse for your own computer. It is
built so that there is nothing to collect.

## What the app collects

**Nothing.** awmouse has no accounts, no analytics, no advertising, no crash
reporting, and no third-party data SDKs. The developer receives no data from
the app, ever.

## What stays on your phone

A few settings are kept on the device so you don't have to re-enter them:

- the address of the computer you last connected to
- your pointer and scroll sensitivity
- a key that identifies your phone to your own computer when connecting over
  the internet (stored in the iOS Keychain)

None of this leaves the phone except as described below, and deleting the app
deletes all of it.

## What leaves your phone, and where it goes

awmouse sends pointer movement, clicks, and scrolling to **the computer you
paired it with** — and only that computer. It never sends anything to the
developer.

**Motion data.** In Air Mouse mode the app reads the gyroscope to work out how
you are tilting the phone. The raw sensor readings are processed on the phone
and discarded; only the resulting cursor movement is sent to your computer.

**The connection.** awmouse uses [Tailcat](https://tailscale.com/tailcat),
which encrypts everything end to end with WireGuard® before it leaves the
phone. To find your computer, the phone briefly contacts one of Tailscale's
public relay servers; that server sees your IP address and an anonymous public
key, cannot read the encrypted traffic, and is bypassed once a direct path to
your computer is found — which, on the same Wi-Fi, is immediate. Tailscale's
own handling of relay traffic is described in
[Tailscale's privacy policy](https://tailscale.com/privacy-policy).

## Permissions the app asks for

- **Local Network** — to reach your computer directly when it is on the same
  Wi-Fi, instead of through the relay.
- **Motion** — to aim the cursor by tilting the phone. Used only in Air Mouse
  mode, only while you hold the screen.

## Children

awmouse is not directed at children and collects no data from anyone.

## Changes

If this policy changes, the new version will be published at this address with
an updated date.

## Contact

Questions: open an issue at <https://github.com/kix99aug/awmouse/issues>.
