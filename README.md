# Offline Photo Finder

A Mac app that finds photos and videos left on an iPhone, entirely offline. It talks to the
iPhone over the USB cable using the open-source [libimobiledevice](https://libimobiledevice.org)
tools, which are bundled inside the app. macOS blocks the app from the internet.

## What it can and can't recover

iOS encrypts every file with its own key and destroys that key when a photo leaves
**Recently Deleted**. No tool can decrypt a permanently deleted photo: not this app, not paid
"recovery" apps, not forensic labs. What survives is **copies and leftovers elsewhere**, and
that's what this app finds:

| Where | How the app gets it |
|---|---|
| Photos app thumbnails, edited versions, iCloud photo cache, shared albums | **Fast copy** of the Photos folders over USB (about 30 MB/s). Each picture is checked against the iPhone's Photos database and iCloud Photos' sync database. It is labelled **Not in library any more** only when there is evidence: a thumbnail or edit whose photo name appears nowhere in the library, or an iCloud cache file whose original iCloud Photos recorded as deleted. Cache files that can't be linked either way get no label. |
| Pictures inside WhatsApp, Telegram, Signal, Messages, Instagram and other apps | **Full backup** over USB (the iPhone spends a few minutes preparing first). |
| Older backups made by Finder or iTunes | **Open an existing backup** (encrypted backups need their backup password). |

With iCloud Photos turned on, iOS leaves the Camera Roll out of backups, so use the fast copy
for anything in the Photos app.

The Photos app also keeps a thumbnail cache in `.ithmb` files. Recent iOS versions compress it in
an undocumented format, so the app copies these files but doesn't turn them into pictures.

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
- **Nothing written to the iPhone.** Backups and copies are only read from it.
- **No third-party services and no third-party Swift code.** Decryption uses Apple's
  CommonCrypto; the database is read with the SQLite that ships with macOS.

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
records where each file came from. Exact duplicates are skipped, and original dates are kept.

## Build

One time, while online:

```bash
brew install libimobiledevice
```

Then, offline is fine:

```bash
cd MacApp && ./build.sh
```

That produces `MacApp/build/Offline Photo Finder.app`, with libimobiledevice copied inside it
and signed locally. No Apple account is needed.

## Use

1. Connect the iPhone with a cable, unlock it and tap **Trust** if asked.
2. Open the app and click **Connect iPhone**.
3. Click **Copy Photos Folders** (fast). Searching starts automatically when the copy finishes.
4. For pictures inside chat apps, also run **Back Up Everything**. On a full iPhone, expect
   several minutes of "preparing" before files arrive.
5. Select pictures, or none to take everything shown, and click **Export**.

## Project layout

```
MacApp/
  Sources/PhotoFinderCore/     backup decryption, scanning, export, USB tools (no UI)
  Sources/OfflinePhotoFinder/  the SwiftUI app
  Sources/photofinder-selftest/ crypto test vectors and a command-line scan for testing
  Scripts/bundle-libimobiledevice.sh   copies libimobiledevice into the app
  Resources/                   Info.plist and the sandbox entitlements
Tools/
  make_test_backup.py          builds a fake encrypted or unencrypted iPhone backup
  make_test_photo_copy.py      builds a fake Photos-folders copy with deleted photos
```

Run the checks:

```bash
cd MacApp && swift build && .build/debug/photofinder-selftest vectors
python3 ../Tools/make_test_backup.py --out /tmp/tb --password test123
PF_PASSWORD=test123 .build/debug/photofinder-selftest scan /tmp/tb --export /tmp/out
```
