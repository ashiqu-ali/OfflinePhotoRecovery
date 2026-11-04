# Security policy

This app exists to handle very private data, so its promises are the core of the project:
**it never sends data off the Mac, it never writes to the iPhone, and it never claims to
recover something that isn't there.** A break in any of these is a security issue.

## What to report

- Any way the app, or a tool it bundles, can reach the network. The sandbox should allow only
  the local USB service socket (`/private/var/run/usbmuxd`).
- Decrypted data left behind in temporary or unexpected locations.
- Crashes, hangs or memory errors caused by a crafted or damaged backup.
- Exports written somewhere other than the folder the user chose.
- A vulnerability in a bundled library (libimobiledevice, libusbmuxd, libplist, OpenSSL) that
  affects how the app uses it.

## How to report

Please **don't open a public issue**. Instead, either:

- use **Report a vulnerability** on the repository's **Security** tab, or
- email **ashiquali007@gmail.com**.

Describe the problem, how to reproduce it, and its impact. **Never include real backups,
photos, databases, names or device identifiers.** Reproduce with the generators in `Tools/`
(`make_test_backup.py`, `make_test_photo_copy.py`) instead.

## What happens next

You'll get an acknowledgement within 7 days. Once the issue is confirmed, it's fixed on `main`
and noted in the [changelog](CHANGELOG.md), with credit to you unless you'd rather stay
anonymous. Please give us a reasonable time to ship the fix before disclosing it publicly.

## Supported versions

Only the latest code on `main` receives security fixes.
