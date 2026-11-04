# Offline Photo Finder

[![CI](https://github.com/ashiqu-ali/OfflinePhotoRecovery/actions/workflows/ci.yml/badge.svg)](https://github.com/ashiqu-ali/OfflinePhotoRecovery/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Mac app that finds photos and videos left on an iPhone, entirely offline. It talks to the
iPhone over the USB cable using the open-source [libimobiledevice](https://libimobiledevice.org)
tools, which are bundled inside the app. macOS blocks the app from the internet.

Alongside the app there is a **recovery toolkit** of small Python scripts (`Tools/recovery/`)
that work on a backup the app (or Finder) has already made: they recover deleted Apple Notes,
pull photos and scans out of deleted notes, unlock password-protected notes when you know or can
guess the password, find screenshots and videos that survive inside chat and editor apps, and
gather the leftovers of deleted Camera Roll items. See **[Recovery toolkit](#recovery-toolkit)**.

## Install and run

**You need:** a Mac with macOS 14 or later, Xcode or its command-line tools,
[Homebrew](https://brew.sh), and the iPhone with its USB cable. Use it only on a device you own.

### 1. Install (one time, needs the internet)

```bash
xcode-select --install            # skip if Xcode is already installed
brew install libimobiledevice     # version 1.4.0 or newer
git clone https://github.com/ashiqu-ali/OfflinePhotoRecovery.git
cd OfflinePhotoRecovery/MacApp
./build.sh
```

`build.sh` creates `MacApp/build/Offline Photo Finder.app`, with libimobiledevice and its license
files inside, signed on your Mac (no Apple account needed). From here on nothing needs the internet.
If an older libimobiledevice is installed, run `brew upgrade libimobiledevice` first.

### 2. Open the app

```bash
open "build/Offline Photo Finder.app"
```

You can also drag it into **Applications**. The green banner at the top confirms that macOS is
blocking the app from the internet.

### 3. Find your photos

1. Connect the iPhone with the cable, unlock it, and tap **Trust** if it asks.
2. Click **Connect iPhone**.
3. Click **Copy Photos Folders**. This is the fast option; searching starts as soon as the copy finishes.
4. In the sidebar, open **In Recently Deleted** and **Not in library any more**. These are what
   survives of deleted photos. Set the size menu to **Any size** to include small thumbnails.
5. For pictures inside WhatsApp, Messages and other apps, and for the Notes scripts, also run
   **Back Up Everything**. The iPhone spends a few minutes preparing first. Keep it unlocked, and set
   **Settings → Display & Brightness → Auto-Lock → Never** until it finishes, because a backup stops
   if the phone locks.
6. Select pictures, or none to take everything shown, and click **Export**.

Already have a backup made by Finder or iTunes? Click **Choose Folder…** on the home screen and pick
it instead. For deleted notes, locked notes and screenshots inside apps, run the scripts in the
**[Recovery toolkit](#recovery-toolkit)** on a finished backup.

### Try it without an iPhone

Make a sample backup, then open it in the app with **Choose Folder…**:

```bash
python3 -I ../Tools/make_test_backup.py --out ~/Desktop/sample-backup --unencrypted
```

## What it can and can't recover

iOS encrypts every file with its own key and destroys that key when a photo leaves
**Recently Deleted**. No tool can decrypt a permanently deleted photo: not this app, not paid
"recovery" apps, not forensic labs. What survives is **copies and leftovers elsewhere**, and
that's what this project finds:

| Where | How it is recovered |
|---|---|
| Photos app thumbnails, edited versions, iCloud photo cache, shared albums | **Fast copy** of the Photos folders over USB (about 30 MB/s). Each picture is checked against the iPhone's Photos database and iCloud Photos' sync database. It is labelled **Not in library any more** only when there is evidence: a thumbnail or edit whose photo name appears nowhere in the library, or an iCloud cache file whose original iCloud Photos recorded as deleted. Cache files that can't be linked either way get no label. |
| Pictures inside WhatsApp, Telegram, Signal, Messages, Instagram and other apps | **Full backup** over USB (the iPhone spends a few minutes preparing first). |
| Items still in **Recently Deleted**, and leftovers of deleted Camera Roll photos | A **full backup or an existing backup** is now compared against the `Photos.sqlite` inside it, so its photos, thumbnails and edits are labelled **In Recently Deleted**, **Not in library any more**, or in-library — the same comparison the fast copy does. Nothing is labelled "deleted" without that evidence. |
| Older backups made by Finder or iTunes | **Open an existing backup** (encrypted backups need their backup password). |
| Deleted Apple Notes and the photos/scans/drawings inside them | **Recovery toolkit** reads the Notes database in a full backup (`notes_search.py`). |
| Password-protected ("locked") notes | **Recovery toolkit** derives the key from the password (`unlock_notes.py`), or searches for a forgotten one (`recover_notes_password.py`). |
| Screenshots and videos saved or shared into other apps | **Recovery toolkit** scans every app's files in a full backup (`screenshot_search.py`, `export_app_videos.py`). |
| Leftovers of deleted Camera Roll photos, screenshots and videos | **Recovery toolkit** matches every surviving thumbnail and edit to the Photos database by folder **and** number (`export_photo_leftovers.py`). |

With iCloud Photos turned on, iOS leaves the Camera Roll out of backups, so use the fast copy
for anything in the Photos app.

The Photos app also keeps a thumbnail cache in `.ithmb` files. Recent iOS versions compress it in
an undocumented format, so the app copies these files but doesn't turn them into pictures.

### The hard limits

The toolkit is honest about what cannot come back, so you don't chase the impossible:

- **A permanently deleted photo's full original** is gone once it leaves Recently Deleted and the
  space is reused. Only copies and leftovers survive.
- **A note iOS has fully erased** leaves at most short text fragments in the database's free space;
  its photos are usually present on disk but **zero bytes**.
- **Locked notes that were deleted and erased** leave their encrypted photo/video files behind,
  but the per-file key is stored in the note's database row, which is gone — so **no password can
  open them**. Only locked notes whose database row still exists can be unlocked.
- **Deleted videos** are not kept in full by iOS; only a small preview frame survives, unless the
  video was also saved or shared into another app.

## Recovery toolkit

Seven read-only Python scripts in `Tools/recovery/`. They need only what ships with macOS
(Python 3 and its `sqlite3`, plus Apple's CommonCrypto via `ctypes` for the unlock tools) — no
pip installs, no network. They read an **unencrypted** iPhone backup folder (one that contains a
`Manifest.db`), never the iPhone directly, and they never modify the backup.

Run each with `python3 -I` so it can't accidentally import anything from the working directory:

```bash
cd Tools/recovery
python3 -I notes_search.py "<backup folder>" "<output folder>"
```

A "backup folder" is the per-device folder the app writes, e.g.
`~/Library/Containers/local.offlinephotofinder/.../Backups/<iPhone ID>/`, or any Finder/iTunes
backup folder. Make sure the backup finished: it must contain `Manifest.db` and its `Status.plist`
must say `SnapshotState = finished`.

### The tools

| Script | What it does |
|---|---|
| `notes_search.py` | Recovers deleted Apple Notes from a backup's `NoteStore.sqlite`. Writes one folder per deleted note (its text as `note.txt`, plus every photo, scan page, drawing, table, link and OCR'd text that survived), carves short text fragments of fully-erased notes from the database free space and write-ahead log, and copies photos whose note is gone entirely. Also gathers everything into an **All note photos in one place** folder and writes a plain-language **Photos that couldn't be recovered.txt** listing what is lost and why. |
| `unlock_notes.py` | Unlocks password-protected notes. Prompts for the Notes password at a hidden prompt (never echoed, stored or logged), derives each object's key with PBKDF2-SHA256 + RFC 3394 unwrap, and decrypts the note body and its attachments with AES-128-GCM. Accepts several attempts (an old password often differs from the current one). |
| `recover_notes_password.py` | Recovers a **forgotten** Notes password by trying likely passwords offline against the note's own key. Reads your guesses from a text file (names, dates, old passwords), automatically also tries each capitalised/UPPERCASE and with common endings (`1`, `123`, `!`, years), and can brute-force numeric PINs (`--pins 6`). It **cannot** break the AES encryption — it only tests guesses, so it succeeds only if the real password is among them. `--deep` widens the mutations. |
| `run_unlock.py` | Non-interactive unlock using an already-recovered password: `python3 -I run_unlock.py "<backup>" "<output>" <password>`. Reuses `unlock_notes.py`. Handy right after `recover_notes_password.py` finds the password. |
| `screenshot_search.py` | Finds screenshots saved or shared **inside apps** (WhatsApp, Messages, Telegram, …) by image shape — phone screens are 9:19.5 — reading PNG/JPEG dimensions straight from the file header. Dedupes by content and sorts the results into one folder per app, with original dates. |
| `export_photo_leftovers.py` | Copies the leftovers of deleted Camera Roll items into the recovery folder: full-size **edited** copies, and small **previews** of deleted photos, screenshots, videos and screen recordings. Dates each from its EXIF or nearest dated neighbour and sorts edited photos by year. It consumes an `orphans.pkl` data file — the list of deleted items matched to the Photos database by folder **and** number — produced by the analysis pass over `Photos.sqlite`; keep that step with the tool if you reuse it. |
| `export_app_videos.py` | Copies full video files out of the apps where a saved or edited recording can survive (VN and other video editors, the Files app) into one folder per app, with each video's pixel size in the filename and phone-screen-shaped ones marked `-SCREEN`. `--screen-only` keeps just those. |

### Typical run

```bash
cd Tools/recovery
B="$HOME/Library/Containers/local.offlinephotofinder/Data/Library/Application Support/Offline Photo Finder/Backups/<iPhone ID>"
OUT="$HOME/Desktop/Recovered"

python3 -I notes_search.py       "$B" "$OUT/Notes"
python3 -I screenshot_search.py  "$B" "$OUT/Screenshots found in apps"
python3 -I export_app_videos.py  "$B" "$OUT/Videos saved in apps"

# Locked notes, if you know the password:
python3 -I unlock_notes.py       "$B" "$OUT/Notes/Unlocked notes"
# …or if you forgot it: add guesses to a text file, then:
python3 -I recover_notes_password.py "$B" guesses.txt --pins 6 --deep
```

### How the Notes crypto works

Apple's "locked notes" use a per-object random key wrapped by your password:

1. `PBKDF2-SHA256(password, ZCRYPTOSALT, ZCRYPTOITERATIONCOUNT)` → a 16-byte key-encrypting key.
2. RFC 3394 unwrap of `ZCRYPTOWRAPPEDKEY` with that key → the object's real key (and, because the
   unwrap has an integrity check, a fast right/wrong-password oracle).
3. AES-128-GCM with the object's key, IV and tag decrypts the note body, its attachment
   metadata, and the attachment files.

Every locked note, attachment and media object carries its own salt, wrapped key, IV and tag, all
derived from the same password. When a locked note is erased, its database row — and therefore its
wrapped key — is deleted, which is why the encrypted leftover files can no longer be opened.

## Does it work on any device?

The **code** is general: iOS stores every backup the same way, so the app and the toolkit read any
iPhone or iPad backup, and the Notes crypto is identical across devices. The **access** is not:
a tool can only read a backup you can make or already hold. To make one, the iPhone must be
physically connected, unlocked with its passcode, and set to **Trust** this Mac. There is no remote
or over-the-air path, and no way around the passcode. In practice that means your own devices, a
device whose owner unlocks it for you, or a backup file you were given — which is the point.

## Why nothing is exposed

- **Internet blocked by macOS.** The app is signed with the App Sandbox and *no* network
  permission (`Resources/OfflinePhotoFinder.entitlements`). The bundled libimobiledevice tools
  inherit the same sandbox. The one exception is `/private/var/run/usbmuxd`, macOS's own local
  service for iPhones on a USB cable, which is a file on this Mac, not a network address.
- **Checked at launch.** The green banner appears only after the app has tried a test
  connection to this Mac's own loopback address and macOS refused it.
- **Check it yourself:**
  ```bash
  codesign -d --entitlements - "MacApp/build/Offline Photo Finder.app"
  ```
  There is no `com.apple.security.network.client` or `network.server` key.
- **Nothing written to the iPhone.** Backups and copies are only read from it; the toolkit opens
  the backup read-only (`mode=ro&immutable=1`) and copies databases to a temp folder before touching them.
- **No third-party services and no third-party Swift code.** Decryption uses Apple's
  CommonCrypto; the database is read with the SQLite that ships with macOS. The Python toolkit uses
  only the standard library and CommonCrypto.
- **Passwords stay local.** `recover_notes_password.py` and `unlock_notes.py` read the password
  from a local file or a hidden prompt, never echo or store it, and send nothing anywhere.

## Where the data goes

Everything is saved on this Mac, in the app's private folder:

```
~/Library/Containers/local.offlinephotofinder/Data/Library/Application Support/Offline Photo Finder/Backups/
  <iPhone ID>/          full backup
  <iPhone ID>-photos/   fast copy of the Photos folders
```

To save them somewhere else, for example an external drive, click **Change…** next to
"Backups and photo copies are saved to" on the home screen or the iPhone screen. The app
remembers that folder, and the bundled tools write straight into it.

The app's home screen lists them, with **Show in Finder** and **Delete**. Exported photos go
wherever you choose, in a new folder with one subfolder per source and an `index.csv` that
records where each file came from. Exact duplicates are skipped, and original dates are kept. The
recovery toolkit writes to whatever output folder you pass it.

## Project layout

```
MacApp/
  Sources/PhotoFinderCore/     backup decryption, scanning, export, USB tools (no UI)
  Sources/OfflinePhotoFinder/  the SwiftUI app
  Sources/photofinder-selftest/ crypto test vectors and a command-line scan for testing
  Scripts/bundle-libimobiledevice.sh   copies libimobiledevice into the app
  Resources/                   Info.plist and the sandbox entitlements
Tools/
  run_checks.sh                runs every automated check (used by CI)
  make_test_backup.py          builds a fake encrypted or unencrypted iPhone backup
  make_test_photo_copy.py      builds a fake Photos-folders copy with deleted photos
  verify_export.py, check_labels.py   assertions used by run_checks.sh
  recovery/                    read-only recovery scripts for a finished backup
    notes_search.py              deleted Apple Notes + their photos/scans/drawings
    unlock_notes.py              unlock password-protected notes (interactive)
    run_unlock.py                unlock with an already-known password (non-interactive)
    recover_notes_password.py    recover a forgotten Notes password by guessing
    screenshot_search.py         screenshots saved inside chat apps
    export_photo_leftovers.py    leftovers of deleted Camera Roll items
    export_app_videos.py         full videos saved inside editor/Files apps
notes/
  ARCHITECTURE_REVIEW.md       senior-architect review: algorithms, findings, roadmap
.github/                       CI, issue and pull request templates, code owners
CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, CHANGELOG.md
LICENSE, THIRD_PARTY_NOTICES.md
```

Run every check, the same ones CI runs (no iPhone needed):

```bash
Tools/run_checks.sh
```

## Use it only on your own devices

This project recovers personal data — photos, private notes, locked notes, chat media. Use it only
on a device you own, or one whose owner has asked you to, and handle what comes out accordingly.
The toolkit's design enforces nothing here; you do.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers the ground
rules (offline only, never write to the iPhone, honest about what can be recovered, no real
personal data anywhere), setup, and `Tools/run_checks.sh`. Everyone follows the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately as described in
[SECURITY.md](SECURITY.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). The app bundles libimobiledevice, libimobiledevice-glue, libusbmuxd, libplist
(LGPL-2.1) and OpenSSL (Apache-2.0), each under its own license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The build copies their license files into the app.
