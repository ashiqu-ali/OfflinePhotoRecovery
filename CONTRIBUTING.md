# Contributing

Thanks for helping. Bug reports, fixes, tests, documentation and support for more iOS versions
are all welcome. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## New here? Start with a good first issue

Pick an issue labelled [`good first issue`][gfi] or [`help wanted`][hw] — they're small, scoped,
and each one says exactly what to do. Comment on the issue to claim it before you start, and ask
anything you're unsure about; questions are welcome. You **don't need an iPhone** to contribute:
`Tools/run_checks.sh` builds the project and runs the whole test suite against generated data.

[gfi]: https://github.com/ashiqu-ali/OfflinePhotoRecovery/labels/good%20first%20issue
[hw]: https://github.com/ashiqu-ali/OfflinePhotoRecovery/labels/help%20wanted

## Ground rules

These protect the people who use this app on their most private data. Pull requests that
break them can't be merged.

1. **Offline, always.** No networking code, no network entitlements, no dependency that phones
   home. The only connection the sandbox allows is the local USB service socket. Changes to
   `MacApp/Resources/OfflinePhotoFinder.entitlements` need a maintainer's review.
2. **Never write to the iPhone.** The app only reads from the device.
3. **Be honest about recovery.** Don't claim the app recovers something it can't. A photo is
   only labelled deleted when there is evidence (see `LibraryIndex.swift`), and permanently
   deleted originals can't be brought back by any tool. Document limits instead of hiding them.
4. **No real personal data, anywhere.** Never commit, attach or paste real backups, photos,
   databases, names, phone numbers or device identifiers, not even in a bug report. Reproduce
   problems with the generators in `Tools/`.
5. **No new dependencies without discussion.** The Swift code uses only what ships with macOS;
   the Python tools use only the standard library.

## Setting up

You need a Mac with Xcode (or its command-line tools), and libimobiledevice from Homebrew to
build the full app. This is the only step that needs the internet:

```bash
brew install libimobiledevice
```

## Building and testing

Run every automated check with one command:

```bash
Tools/run_checks.sh
```

It builds the Swift package, runs the crypto and file-format checks, then generates encrypted,
unencrypted and Photos-folder test data and checks that every file is found, exported
byte-for-byte and labelled correctly. It needs no iPhone.

To build the signed app itself:

```bash
cd MacApp && ./build.sh
```

To try it with a real iPhone, use one you own.

## Making a change

1. Open an issue first for anything larger than a small fix, so the approach can be agreed.
2. Create a branch from `main`, for example `fix/wal-manifest` or `feature/notes-export`.
3. Keep the pull request focused on one change, and add or update tests:
   - a test vector in `MacApp/Sources/photofinder-selftest/main.swift` for crypto or parsing;
   - a case in `Tools/make_test_backup.py` or `Tools/make_test_photo_copy.py`, plus an
     expectation in `Tools/run_checks.sh`, for anything about what gets found or labelled.
4. Update the README and add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
5. Run `Tools/run_checks.sh` and make sure it passes.
6. Open the pull request and fill in its checklist.

### Style

- Match the code around your change: naming, comments and structure.
- Swift: four-space indentation, small types, errors with clear user-facing messages.
- Python: standard library only, run with `python3 -I`.
- Commit messages: a short imperative summary line ("Fix reading WAL-mode Manifest.db"), then
  a body explaining why.

## Licensing

By contributing, you agree that your contribution is licensed under the project's
[MIT license](LICENSE). The bundled third-party components keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
