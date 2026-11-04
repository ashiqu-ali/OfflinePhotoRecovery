# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Nothing has been released yet.

## [Unreleased]

### Added

- Sandboxed macOS app with no network access; the only connection it can make is the local USB
  service socket, and it checks at launch that the internet is blocked.
- Full iPhone backups and a fast copy of the Photos app's folders over USB, using bundled
  libimobiledevice tools.
- Reading encrypted backups (with the backup password) and unencrypted ones.
- Finding photos and videos by their content, including inside other apps.
- Comparing found items against the Photos library, in both copies and backups: **In Recently
  Deleted**, **Not in library any more**, or in-library.
- Exporting with an `index.csv` of where each file came from, skipping exact duplicates.
- Choosing where backups and copies are saved, for example an external drive.
- Recovery toolkit scripts for Notes, screenshots, videos and photo leftovers.
- Open-source project files: MIT license, Contributor Covenant code of conduct, contributing
  guide, security policy, issue and pull request templates, CI and `Tools/run_checks.sh`.
- The bundled libraries' license files are copied into the app.

### Fixed

- Reading `Manifest.db` that iOS wrote in WAL mode.
- Searching a backup before it has finished; this now shows a clear message.
- Photos filed under another DCIM folder being wrongly labelled as not in the library.
- iCloud cache files being labelled deleted without evidence.
- A slow device query that held up backups for many minutes.
