# Offline Photo Finder: architecture review

Review of commit `4701836` (the only commit), branch `fayiz/notes`, 3 November 2026.
About 3,500 lines: 2,560 Swift, 300 Python, 100 shell.

**How this was reviewed:** every file was read in full. Afterwards the app was built with
`build.sh` (after upgrading Homebrew's libimobiledevice from 1.3.0 to 1.4.0, see finding B1) and
launched. It was **not tested against an iPhone or a real backup**, so anything about runtime
behaviour is inferred from the source and marked as such.

---

## 1. Executive summary

Offline Photo Finder is a sandboxed macOS SwiftUI app. It finds photos and videos that are still
on an iPhone, or in a backup of one, without ever touching the network. It does **not** undelete
anything: iOS uses per-file encryption, so a permanently deleted photo can't be recovered. The app
recovers **copies and leftovers**: thumbnails, edited renders, the iCloud Photos cache, shared
albums, chat-app media and Messages attachments. When it has evidence, it labels which of them
belong to photos that are no longer in the library.

The engineering quality is high for a first commit. Core logic is cleanly separated from the UI.
There's no third-party Swift code. The crypto is correct and tested against RFC vectors, and the
privacy posture is unusually honest and verifiable. The main weaknesses are:

1. **The build fails on a Mac with an older libimobiledevice.** The build script needs `afcclient`,
   which is in libimobiledevice 1.4.0 and later. The README doesn't name a minimum version, and an
   existing 1.3.0 install fails with a misleading message.
2. **Reliability gaps in the device pipeline.** A failed copy is reported as a success, there are
   no timeouts, and only the first connected iPhone is used.
3. **The empty-library case.** It can hide every "Not in library" label exactly when the user
   needs them most.
4. **Performance at scale.** Thumbnails decrypt whole files, image loads can't be cancelled, and
   filters run on every redraw.
5. **No automated tests or CI**, and no way to distribute the app to other Macs (no Developer ID
   signing, notarization or license notices).

The biggest product opportunities are:
- Pull **context from app databases**: which chat a photo came from and when, plus the original
  capture date and place from `Photos.sqlite`.
- Recover **images embedded inside databases and caches**, which the scanner currently skips.
- **Group near-duplicates** so each thumbnail sits with its original.
- **Remember scan results**, so a backup doesn't have to be searched again every time.

---

## 2. What the app does

| Pipeline | Input | Output |
|---|---|---|
| **Fast photo-folder copy** | iPhone over USB, through AFC (`afcclient get -rf`) of `PhotoData`, `PhotoStreamsData`, `CloudAssets`, `LoFiCloudAssets`, `Photos`, `Downloads`, and optionally `DCIM` | `<UDID>-photos/` folder plus a marker plist |
| **Full backup** | iPhone over USB (`idevicebackup2 backup`, incremental) | Standard iOS backup folder `<UDID>/` |
| **Open existing backup** | Folder made by Finder or iTunes, or a copy of one | Read in place, never modified |

All three pipelines feed one engine: **list files → filter → identify by content → classify the
source → label library status → show in a grid → export with provenance**.

What is explicitly out of scope, and correctly so: iCloud backups, Android, decrypting deleted
files (not possible), and `.ithmb` thumbnail caches (undocumented compression).

---

## 3. Architecture

```
┌──────────────────────────── OfflinePhotoFinder (SwiftUI app, @MainActor) ────────────────────────────┐
│ App.swift ─ ContentView (screen switch) ─ OfflineBanner                                             │
│ HomeAndDeviceViews · ScanViews · ResultsView   ← views                                              │
│ AppModel (540 lines): navigation, device flow, storage location, scan, filters, selection, export   │
│ ThumbnailLoader (NSCache + OperationQueue×4) · OfflineGuard (sandbox self-check) · WindowSnapshot   │
└───────────────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                                │ (no UI types cross this line)
┌──────────────────────────────── PhotoFinderCore (library, no UI) ───────────────────────────────────┐
│ DeviceTools / PhotoFolderCopyJob / DeviceBackupJob  → Process() → bundled libimobiledevice CLIs     │
│ BackupLocator → BackupSummary            BackupReader → Keybag → Crypto (CommonCrypto)              │
│ ManifestDatabase (SQLite C API)          Scanner → MediaSniffer + SourceClassifier + LibraryIndex   │
│ Exporter (stream decrypt + SHA-256 + CSV)                                                           │
└───────────────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                                │
        macOS: App Sandbox (no network) · usbmuxd socket (only exception) · CommonCrypto · sqlite3
```

**Targets** ([Package.swift](../MacApp/Package.swift)): `PhotoFinderCore` (library),
`OfflinePhotoFinder` (app), `photofinder-selftest` (a command-line tool for crypto vectors and scan
or export).

**Build** ([build.sh](../MacApp/build.sh)): `swift build -c release` assembles the `.app` by hand.
[bundle-libimobiledevice.sh](../MacApp/Scripts/bundle-libimobiledevice.sh) then copies five
Homebrew command-line tools and their whole dylib dependency tree into the bundle, rewrites the
library paths to `@rpath`, and signs it ad hoc with the sandbox entitlements.

**Concurrency model:** UI state is on `@MainActor`. Long work runs in `Task.detached`. File
identification fans out with `DispatchQueue.concurrentPerform`. Cancellation uses lock-protected
flags, and process cancellation sends `SIGINT` to the child tool.

---

## 4. The algorithms, in detail

### 4.1 Encrypted backup decryption (iOS 10.2+ format)
Files: [Keybag.swift](../MacApp/Sources/PhotoFinderCore/Keybag.swift),
[Crypto.swift](../MacApp/Sources/PhotoFinderCore/Crypto.swift),
[Backup.swift](../MacApp/Sources/PhotoFinderCore/Backup.swift)

1. **Parse the keybag.** `Manifest.plist › BackupKeyBag` is a tag-length-value stream: a 4-byte tag
   and a 4-byte big-endian length. The first `UUID` and `WRAP` belong to the header. Each later
   `UUID` starts a class-key record with `CLAS`, `WRAP`, `WPKY`, `KTYP` and `PBKY`.
2. **Derive the password key** the way iOS does. The password goes through PBKDF2-HMAC-SHA256 with
   salt `DPSL` for `DPIC` rounds (about 10 million, deliberately slow), then PBKDF2-HMAC-SHA1 with
   salt `SALT` for `ITER` rounds, giving a 32-byte key.
3. **Unwrap the class keys.** Each class key with `WRAP & 2` (passcode-wrapped) is unwrapped with
   **RFC 3394 AES Key Unwrap**, implemented by hand over single-block AES-ECB. A failed integrity
   check (`A ≠ 0xA6…A6`) means the password is wrong.
4. **Decrypt `Manifest.db`.** `ManifestKey` holds a 4-byte little-endian protection class followed
   by a wrapped key. That key decrypts `Manifest.db` with **AES-256-CBC and a zero IV**, followed by
   PKCS#7 removal and a check for the `SQLite format 3` header.
5. **Decrypt each file.** Each `Files.file` value is an `NSKeyedArchiver` `MBFile` record, decoded
   through a custom `NSSecureCoding` class. Its `EncryptionKey` is a 4-byte class plus a 40-byte
   wrapped key, unwrapped with that class's key. The file is then streamed through AES-CBC
   (CommonCrypto `CCCryptor`, in 1 MB chunks) and cut at `MBFile.Size` instead of trusting the
   padding.

The code is correct, small, and checked against RFC 3394 and RFC 6070 test values plus a
fixture generator that shares no code with the app. **Gap:** no test decrypts a *real* iOS
backup; the fixture is synthetic.

### 4.2 Choosing which files to inspect
File: [Scanner.swift](../MacApp/Sources/PhotoFinderCore/Scanner.swift)
- For backups, it lists `Files` rows with `flags = 1` (regular files) from the decrypted manifest.
  For folder copies, it walks the folder with `FileManager.enumerator`, mapping `DCIM/` and
  `PhotoData/` to `CameraRollDomain` and everything else to `MediaDomain`, so a single classifier
  handles both.
- **Cheap rejection** comes first: a fixed list of about 40 extensions that are never media (plist,
  sqlite, json, m4a, pdf, ithmb…), and a 1 KB minimum size. Most of a backup is ruled out without
  being opened.

### 4.3 Identifying a file by its content
File: [MediaSniffer.swift](../MacApp/Sources/PhotoFinderCore/MediaSniffer.swift)
- It reads the **first 32 bytes**, decrypting only the first blocks for encrypted backups, and
  matches signatures: JPEG `FFD8FF`, PNG, GIF87a/89a, RIFF…WEBP, and TIFF (II* / MM*).
- For the ISO media container family (`ftyp` box at offset 4), the major brand decides:
  `heic/heix/mif1…` is a HEIC photo, `avif/avis` is AVIF, M4A/M4B/M4P audio and `crx ` are
  rejected, `qt  ` is a MOV, `3g*` is 3GP, and anything else is treated as an MP4 video.
  Bare QuickTime atoms (`moov/mdat/wide/pnot`) count as MOV.
- Why this matters: app caches use hashed names with no extension, so content decides, not the
  name.

### 4.4 Parallel scanning
Candidates are split into chunks of 64 and processed with `DispatchQueue.concurrentPerform`, so
every CPU core reads file headers at once. Results and counts merge under one `NSLock`, and
progress is reported every 8 chunks. The reader is stateless per call (a new `FileHandle` each
time), so concurrent reads are safe.

### 4.5 Naming where a file came from
File: [SourceClassifier.swift](../MacApp/Sources/PhotoFinderCore/SourceClassifier.swift)
Rules on domain and path give labels such as Camera Roll, Thumbnails, Edited Versions, iCloud
cache, Shared Albums, Messages and Downloads. App domains
(`AppDomain-`, `AppDomainGroup-`, `AppDomainPlugin-`, `Sys*ContainerDomain-`) have their prefix and
any `group.` prefix removed, then match a table of 24 known app identifiers. Unknown apps show
their raw identifier.

### 4.6 "Not in library any more": the main inference
File: [LibraryIndex.swift](../MacApp/Sources/PhotoFinderCore/LibraryIndex.swift).
It runs **only for photo-folder copies**.

1. It opens *private copies* of `Photos.sqlite` (with its `-wal`/`-shm` files) and
   `CPL/storage/store.cloudphotodb`.
2. **Name index:** `ZASSET.ZFILENAME` (or `ZGENERICASSET` before iOS 14), reduced to the stem, maps
   to `inLibrary`, or to `recentlyDeleted` when `ZTRASHEDSTATE ≠ 0`.
   `ZADDITIONALASSETATTRIBUTES.ZORIGINALFILENAME` adds renamed imports. The DCIM folder is ignored
   on purpose, because iOS can file thumbnails under a different `1xxAPPLE` folder.
3. **Fingerprint index (iCloud cache):** fingerprints of photos still in the library come from
   `ZINTERNALRESOURCE`, `ZCLOUDRESOURCE`, `ZADDITIONALASSETATTRIBUTES` (master and adjusted),
   `ZCLOUDMASTER` IDs, and `outgoingResources` linked to known asset or master IDs. Fingerprints of
   deleted photos come from `pushRepository` (`CPLMasterChange`, `trashed = 1`) and `idMapping`
   rows with a delete timestamp, minus anything known to be in the library.
4. **Matching each file to the library:**
   - Thumbnails (`Thumbnails/V2/…/IMG_0001.JPG/5005.JPG`), edits
     (`Mutations/DCIM/…/IMG_0001/Adjustments/…`) and DCIM originals: the name stem is looked up,
     and **not found means `notInLibrary`**.
   - iCloud cache files (`cpl<fingerprint>.<ext>`): in the library if the fingerprint is known, not
     in the library if it's in the deleted set, otherwise **no label**.
   - Everything else gets no label.
   - Each query runs separately and fails quietly, so a schema change in one iOS version only turns
     off its own check.

This is a careful, evidence-based design: the app gives no label rather than a wrong one. Its weak
points are covered in findings B3, B4 and C6.

### 4.7 Export
File: [Exporter.swift](../MacApp/Sources/PhotoFinderCore/Exporter.swift)
- **Order:** Camera Roll first, apps and caches next, thumbnails last, keeping the original order
  within each group. When duplicates appear, the copy kept is the best one.
- Each file is **streamed through decryption into its destination while SHA-256 is computed**. If
  the hash was already seen, the new copy is deleted and recorded as a duplicate. That's exact
  matching only.
- Names: thumbnails become `IMG_0001-thumbnail.jpg`, edits become `IMG_0001-edited.jpg`, names
  without an extension get the detected one, and clashes get `" (2)"`. Original modified and
  created dates are restored on the files.
- `index.csv` records the exported file, source, kind, domain, original path, size, modified date,
  SHA-256 and a note (for duplicates or failures). The output has one subfolder per source.

### 4.8 Device input and output
File: [DeviceTools.swift](../MacApp/Sources/PhotoFinderCore/DeviceTools.swift)
- **Detection:** `idevice_id -l` every 2 seconds. **Pairing:** `idevicepair validate`, falling back
  to `pair`, and parsing the output for "trust", "passcode" or "locked" to show the "Tap Trust"
  screen.
- **Device details:** `ideviceinfo` (top level, plus the `com.apple.mobile.backup` `WillEncrypt`
  setting) and `afcclient devinfo` for storage. It deliberately avoids the `disk_usage` query,
  which can keep a busy iPhone occupied for many minutes.
- **Fast copy:** one `afcclient get -rf` per folder. It reads stdout without blocking, uses a regex
  for `NN% (x MB/s)`, and logs any line containing "error".
- **Backup:** `idevicebackup2 backup <dir>`. Lines are split on `\r` or `\n`, `[====] NN% (a/b)`
  becomes progress, and the last 6 lines are kept for error reports.

### 4.9 The offline guarantee
- [OfflinePhotoFinder.entitlements](../MacApp/Resources/OfflinePhotoFinder.entitlements): App
  Sandbox on, **no** `network.client` or `network.server`. The only exception is an SBPL rule
  allowing `network-outbound` to the `/private/var/run/usbmuxd` socket file. Child processes
  inherit the sandbox.
- [OfflineGuard.swift](../MacApp/Sources/OfflinePhotoFinder/OfflineGuard.swift) proves it at
  launch. It reads its own entitlements through `SecTaskCopyValueForEntitlement` and attempts a
  TCP `connect()` to `127.0.0.1:9`. The green banner appears only when that fails with `EPERM`
  or `EACCES` (blocked by the sandbox, not merely refused).

---

## 5. Strengths to keep

- **Honest scope:** the README explains *why* deleted photos can't be decrypted, and the "no label
  rather than a wrong label" policy is built into the code.
- **Real security boundary:** offline is enforced by the operating system, can be checked with
  `codesign`, and is self-tested at runtime.
- **No third-party Swift code;** the crypto uses CommonCrypto with RFC test values. The Python
  fixtures are independent of the app's code.
- **Clean layering:** the Core module has no UI types, so it can be reused (the self-test tool
  already uses it).
- **Memory-safe streaming** for decryption and export, which handles large videos.
- **Provenance in every export** through `index.csv` with SHA-256.
- **Small and readable,** with comments that explain *why*.

---

## 6. Findings: bugs and risks, by severity

Severity: **High** means wrong results or the app can't be used. **Medium** means reliability,
privacy or performance problems. **Low** means polish.

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| B1 | Medium | **The build needs libimobiledevice 1.4.0 or later, but doesn't say so.** The bundling script requires `afcclient`, which 1.3.0 doesn't have. On this Mac, 1.3.0 was installed and the build failed with "install it: brew install libimobiledevice", which doesn't help when it's already installed. After `brew upgrade libimobiledevice` (to 1.4.0_2), `build.sh` succeeded. | [bundle-libimobiledevice.sh:12-19](../MacApp/Scripts/bundle-libimobiledevice.sh), [README.md:66](../README.md) | State the minimum version in the README. Have the script check the version and suggest `brew upgrade libimobiledevice`. |
| B2 | **High** | **A failed fast copy is reported as success.** The `afcclient` exit status is never checked, and the marker plist is written anyway, so a copy cut short by a pulled cable or locked phone looks complete and is searched as if it were whole. | [DeviceTools.swift:203-212](../MacApp/Sources/PhotoFinderCore/DeviceTools.swift) | Check `terminationStatus` for each folder. Record per-folder status and `complete: Bool` in the marker. Show "partial copy" in the UI. |
| B3 | **High** | **An empty library disables all labels.** If `ZASSET` exists but has no rows (every photo deleted, which is the most likely case for a recovery user), `names` is empty and `LibraryIndex` returns `nil`. No "Not in library" labels appear at all. | [LibraryIndex.swift:28-38](../MacApp/Sources/PhotoFinderCore/LibraryIndex.swift) | Tell "table missing" apart from "table empty". Return a valid index when the table exists with zero rows. |
| B4 | Medium | **Name-only matching misses deleted photos.** The stem `IMG_0146` is shared across `100APPLE…1xxAPPLE` once the counter wraps. A deleted `IMG_0146` is treated as in the library if any other `IMG_0146` still exists. That's safe, but some deleted photos are never flagged. | [LibraryIndex.swift:12-14, 90-91](../MacApp/Sources/PhotoFinderCore/LibraryIndex.swift) | Key on `ZDIRECTORY + ZFILENAME` first, and fall back to the stem only when the folder doesn't match anything. *Testing showed* matching on folder and name finds materially more deleted items than matching on the name alone, so the fallback is essential. |
| B5 | Medium | **Copying a live `Photos.sqlite` can give an inconsistent snapshot.** AFC copies the database and its WAL at different moments while iOS may be writing. DCIM files that aren't found are labelled `notInLibrary` (no "unknown" state), so a stale snapshot can produce false "Not in library" labels. *Inferred; not tested.* | [LibraryIndex.swift:91](../MacApp/Sources/PhotoFinderCore/LibraryIndex.swift), [DeviceTools.swift:174-204](../MacApp/Sources/PhotoFinderCore/DeviceTools.swift) | Copy `PhotoData/Photos.sqlite*` last and quickly, then compare its newest date with the other files. Report "library snapshot may be stale" when they disagree. |
| B6 | Medium | **Decrypted data is written to disk.** The decrypted `Manifest.db` and decrypted video previews go to the temporary folder. They're deleted with `defer`, but a crash leaves them behind, which partly defeats an encrypted backup. | [Backup.swift:182-202](../MacApp/Sources/PhotoFinderCore/Backup.swift), [ThumbnailLoader.swift:50-55](../MacApp/Sources/OfflinePhotoFinder/ThumbnailLoader.swift) | Open the manifest in memory (`sqlite3_deserialize`). Play video through an `AVAssetResourceLoader` that decrypts on the fly. Clear the temporary folder at launch. |
| B7 | Medium | **Device commands have no timeout.** `DeviceTools.run` blocks until the tool exits. A hung `idevicepair` or `ideviceinfo` leaves the UI on "Connecting…" forever. | [DeviceTools.swift:62-74](../MacApp/Sources/PhotoFinderCore/DeviceTools.swift) | Add a timeout per call (terminate, then kill). Show "the iPhone isn't responding, unplug and replug". |
| B8 | Medium | **Only the first iPhone is used.** `ids.first` is picked silently. | [AppModel.swift:288-291](../MacApp/Sources/OfflinePhotoFinder/AppModel.swift) | Let the user choose a device when more than one is connected. |
| B9 | Medium | **Thumbnails are slow and memory-hungry.** A grid tile decrypts the *whole file* into memory (up to 200 MB). `FromImageAlways` ignores the preview already embedded in the photo. Videos are fully decrypted to the temporary folder, even when unencrypted. Up to 4 run at once and they can't be cancelled, so fast scrolling builds a backlog. | [ThumbnailLoader.swift:21-67](../MacApp/Sources/OfflinePhotoFinder/ThumbnailLoader.swift) | Use `FromImageIfAbsent` with a streaming image source. Read unencrypted files straight from their URL. Make loads cancellable when a tile scrolls away. |
| B10 | Medium | **Filters run on every redraw.** `visibleItems`, `sourceCounts` and `libraryCounts` are computed properties that each pass over every item whenever the view body is evaluated, including during thumbnail loading and selection changes. With 100,000+ items the UI stutters. *Inferred.* | [AppModel.swift:469-499](../MacApp/Sources/OfflinePhotoFinder/AppModel.swift) | Pre-group items by source after the scan, and recompute only when a filter changes. |
| B11 | Medium | **Incomplete backups are listed as normal.** `Status.plist` `SnapshotState` is never checked, so an interrupted backup appears like any other and many of its files show up as "unreadable". | [Backup.swift:71-93](../MacApp/Sources/PhotoFinderCore/Backup.swift) | Read `Status.plist` and mark incomplete backups clearly. |
| B12 | Low | **Delete is permanent.** It uses `removeItem` instead of moving to the Trash, although there is a confirmation dialog. | [AppModel.swift:220-227](../MacApp/Sources/OfflinePhotoFinder/AppModel.swift) | Use `FileManager.trashItem`. |
| B13 | Low | **The CSV can trigger formulas.** File names from the iPhone (for example names chosen by a chat sender) beginning with `=`, `+`, `-` or `@` are written unescaped, so a spreadsheet may treat them as formulas. | [Exporter.swift:112-115](../MacApp/Sources/PhotoFinderCore/Exporter.swift) | Put a `'` in front of such values. |
| B14 | Low | **DNG and ProRAW are exported as `.tiff`** because they share TIFF's signature. There's no detection for BMP, JPEG XL, WebM/MKV or AVI. | [MediaSniffer.swift:30-32](../MacApp/Sources/PhotoFinderCore/MediaSniffer.swift) | Look for DNG tags, and add the missing signatures. |
| B15 | Medium | **Fast-copy file dates are the copy date.** *Confirmed in testing:* `afcclient get` doesn't keep the iPhone's modified times, so every folder-copy item sorts and exports with the date it was copied, not the date the photo was taken. | [Scanner.swift:90-109](../MacApp/Sources/PhotoFinderCore/Scanner.swift) | Check on a device. Either way, prefer dates from `Photos.sqlite` (`ZDATECREATED`) or the photo's EXIF data. |
| B16 | Low | **Duplicates are written in full before being discarded.** Every duplicate is fully copied and hashed, then deleted. | [Exporter.swift:49-55](../MacApp/Sources/PhotoFinderCore/Exporter.swift) | For unencrypted sources, hash first and skip the copy when the hash was already seen. |
| B17 | Low | **The password stays in a published string.** It sits in a `@Published String` until the scan succeeds. | [AppModel.swift:69](../MacApp/Sources/OfflinePhotoFinder/AppModel.swift) | Minor. Clear it after use or on failure, and keep it in a local variable only. |

---

## 7. What is missing (should be implemented)

These are gaps against what the product already promises, or basic expectations for a recovery
tool.

1. **A reproducible build and a release process.** Fix B1. Then add **hardened runtime**
   (`codesign --options runtime`), **Developer ID signing and notarization**, and a DMG. Today the
   app is signed ad hoc, so Gatekeeper blocks it on any other Mac. Also check that notarization
   accepts the `temporary-exception.sbpl` entitlement. It definitely rules out the Mac App Store,
   so distribution is direct only.
2. **License notices for bundled libraries.** The app ships libimobiledevice, libplist, libusbmuxd
   and libimobiledevice-glue (LGPL-2.1) plus OpenSSL (Apache-2.0) dylibs. LGPL requires the
   notices and lets users swap in their own builds of those libraries. Add an Acknowledgements
   screen and a `LICENSES/` folder. The README's "no third-party code" claim should say "no
   third-party *Swift* code, but bundled open-source C tools".
3. **Automated tests.** There is no XCTest or `swift test` target. `photofinder-selftest scan`
   prints its results but never compares them with the `expected.json` that the fixture
   generator writes. Add:
   - Unit tests: keybag parsing, key unwrap, signatures, classifier, CSV escaping, unique names.
   - Golden tests: generate fixtures, scan them, and compare the hashes and labels in
     `expected.json`.
   - LibraryIndex scenarios: empty library (B3), counter wraparound (B4), stale WAL (B5).
4. **CI:** GitHub Actions on `macos-latest` running `swift build`, the tests, and a lint check that
   no `network` entitlement has been added.
5. **Library labels for full backups.** `LibraryIndex` runs only for folder copies
   ([Scanner.swift:79-80](../MacApp/Sources/PhotoFinderCore/Scanner.swift)). When iCloud Photos is
   off, a full backup contains `CameraRollDomain/Media/PhotoData/Photos.sqlite` and thumbnails, so
   the same labels could apply there.
6. **Partial or interrupted job handling:** B2, B11, and **resuming** a fast copy. Skip files
   already present with the same size and date instead of overwriting everything with `-f`.
7. **Choosing the device and handling hangs:** B7 and B8.
8. **Remembering results.** Every "Search" scans again from scratch. Save an index per backup
   (a SQLite file in the app container) so reopening is instant and selections survive a restart.
9. **Better results browsing:** sort by date, size or name. Search by file name. Shift-click range
   selection and keyboard navigation. Quick Look (space bar). Real video playback in the preview.
10. **Localization and accessibility:** all text is hard-coded English, and grid tiles have no
    accessibility labels.

---

## 8. Features that could be added (roadmap)

Effort: S is up to 2 days, M is about a week, L is several weeks. Everything stays offline and
on-device.

### Now: high value, fits the existing design
| Feature | What and why | Effort |
|---|---|---|
| **Context from chat-app databases** | WhatsApp `ChatStorage.sqlite` (`ZWAMEDIAITEM` and `ZWAMESSAGE`) and Messages `sms.db` (`attachment`, `message_attachment_join`, `chat`, `handle`) record, for each media file, **which chat, who sent it and when**. Show "From chat with Alex, 12 Mar 2024" on each tile, filter by chat, and add columns to `index.csv`. This is the biggest jump in usefulness for chat-app recovery. | M |
| **Real dates and places from `Photos.sqlite`** | `ZASSET.ZDATECREATED`, `ZLATITUDE/ZLONGITUDE`, favourites and album membership. On export, write the correct capture date into the file, and optionally into EXIF or an XMP sidecar. That fixes date problems (B15) and lets the Mac's Photos app sort recovered items correctly. | M |
| **Live Photo pairing** | A HEIC and a MOV with the same stem and asset are linked and shown and exported as one item. | S |
| **Grouping near-duplicates** | A perceptual hash (dHash with vImage) or Vision's on-device `VNGenerateImageFeaturePrintRequest` groups each thumbnail, edit, cache copy and chat recompression with its original. Pick the best version automatically and offer "export best of each group". | M |
| **Export options** | Folder layout (by source, by date, flat), HEIC to JPEG conversion, "keep only the largest of each group", and direct import into Photos on the Mac (PhotoKit, works offline). | M |
| **Summary report** | A PDF or HTML report: device, iOS version, sources, counts, what was labelled and why, with hashes. Useful for family IT help and for proving provenance. | S |

### Next: recovers *more* photos
| Feature | What and why | Effort |
|---|---|---|
| **Images embedded in databases and caches** | The scanner skips `.db`, `.sqlite` and `-wal` files entirely. Some apps store images *inside* them, for example inline thumbnails and previews in chat or notes databases, and WAL files can hold older versions of pages. Search the stored values and WAL pages for JPEG, PNG and HEIC signatures, and extract complete images. (`Library/Caches` folders, where network caches usually live, aren't included in backups, so check on real backups which databases are worth it.) | M |
| **Recovering deleted rows from SQLite** | Deleted rows often survive in a database's free pages and WAL. Recovering deleted `ZASSET` rows from `Photos.sqlite` would give names and dates for orphan thumbnails, turning "unknown" into "Not in library, taken 3 May 2023". | L |
| **App screenshot snapshots** | iOS keeps screenshots of app screens (`Library/SplashBoard/Snapshots/*.ktx`). They can show photos the user viewed. Where they appear in a backup, decode KTX and show them as "App snapshots". First check on a real backup that they're included. | M |
| **Decoding `.ithmb` thumbnails** | Already copied, but not readable. A research task: reverse-engineer the compression used by current iOS. Big payoff if solved. | L (research) |
| **More app parsers** | Telegram (Postbox), Signal (encrypted SQLCipher; the key needs the device's keychain, so probably not feasible offline from a backup), Instagram, Snapchat and Facebook caches. Add each as a plug-in source adapter (section 10). | M each |

### Later: product polish and reach
| Feature | What and why | Effort |
|---|---|---|
| **On-device content search** | Vision `VNClassifyImageRequest` (offline) to search "beach", "dog" or "document", plus face grouping. Stays private. | M |
| **Timeline and map views** | Browse by month, or on a map using the Photos.sqlite coordinates (map tiles need a network, so use an offline vector outline or plain coordinates). | M |
| **Command-line tool** | Turn `photofinder-selftest scan/export` into a proper `photofinder` CLI for advanced users and scripted runs, with JSON output. | S |
| **Data clean-up assistant** | After exporting, "Securely remove all copies and backups made by this app". Warn when an unencrypted backup is sitting on disk. | S |
| **Guided encryption** | Explain how to turn on backup encryption (encrypted backups contain more app data) and how to reset a forgotten backup password on the iPhone (Settings › General › Transfer or Reset iPhone › Reset › Reset All Settings). | S |

---

### Additional gaps (recovery features)

| Gap | Detail |
|---|---|
| **No Notes recovery at all** | The app only looks for photos and videos. Apple Notes (`AppDomainGroup-group.com.apple.notes/NoteStore.sqlite`) is never read, so deleted notes can't be found, even in Recently Deleted. That needs a full backup plus a Notes parser: current notes, Recently Deleted, and fragments left in the database's free pages and WAL. **Priority: high**, because users expect it. |
| **No "Screenshots" view** | Screenshots are `ZKINDSUBTYPE = 10` in Photos.sqlite, and their thumbnails sit under `IMG_xxxx.PNG/` folders. Many leftovers of deleted items are screenshots, so add a Screenshots filter. |
| **Leftovers are mostly old** | iOS cleans up thumbnails of recent deletions, so the leftovers that survive tend to be older. Set expectations in the UI: recent deletions rarely leave anything behind. |
| **Chat copies of screenshots** | Screenshots sent through WhatsApp or Messages are full-size copies, recoverable from a full backup. Point users there when they're searching for screenshots. |

## 9. Engineering and platform recommendations

- **Swift 6 language mode.** Closures passed to `concurrentPerform` and the progress callbacks
  aren't marked `@Sendable`, and `@unchecked Sendable` is used on `BackupReader` and the job
  classes. Adopt strict concurrency now while the code is small. Replace progress closures with
  `AsyncStream`, and cancellation flags with `Task` cancellation.
- **Split up `AppModel`** (540 lines). It handles navigation, the device flow, storage, scanning,
  filtering, selection and export. Split it into `DeviceSession`, `StorageLocation`, `ScanSession`
  and `ExportCoordinator`, and keep `AppModel` as a thin router. That also makes each part
  testable without the UI.
- **Make device access swappable.** Put the command-line wrappers behind a protocol
  (`DeviceTransport`) so the device flow can be tested with a fake that replays recorded tool
  output. Parse version information so that tool output changes don't silently break the progress
  regexes.
- **Schema compatibility matrix.** Keep one `Photos.sqlite` and `store.cloudphotodb` fixture per
  major iOS version (16, 17, 18, 26), plus the path conventions for thumbnails and Mutations. Add
  a test for each.
- **Logging.** Use `os.Logger` with privacy annotations, and an "Export diagnostics" button
  (log only, no media) for support.
- **Use the macOS 14 baseline.** Swift Observation (`@Observable`) cuts unnecessary redraws
  (helps with B10).

---

## 10. Suggested target architecture

```
PhotoFinderCore
  Sources/            ← one adapter per kind of input
    BackupSource          (Manifest.db, encrypted or plain)
    PhotoFolderSource     (AFC copy)
    protocol MediaSource { func enumerate() -> AsyncStream<Candidate>; func open(_:) -> ReadStream }
  Pipeline/
    CandidateFilter → ContentSniffer → Enrichers[] → Catalog
  Enrichers/          ← plug-ins add context to an item
    PhotosLibraryEnricher   (status, capture date, GPS, Live Photo pair)
    WhatsAppEnricher, MessagesEnricher, …
    PerceptualHashEnricher  (duplicate groups)
  Carvers/            ← find media inside other files
    SQLiteBlobCarver, WALCarver, KTXSnapshotDecoder
  Catalog/            ← saved index (SQLite in the app container)
  Export/             ← layouts, conversion, CSV, report
  Device/
    protocol DeviceTransport; LibimobiledeviceTransport; FakeTransport (tests)
App
  Feature stores (@Observable): DeviceSession · ScanSession · Browser · Export
```

Why this shape: each new app or data source becomes an **Enricher** or **Carver** without touching
the scanner. Results are saved once and browsed instantly. Everything that talks to the device or
the file system can be faked in tests.

---

## 11. Suggested order of work

1. **Week 1: correctness and build.** B1, B2, B3, B11, B7. Add `swift test` with golden fixtures
   and CI.
2. **Weeks 2-3: performance and safety.** B9, B10, B6, B5. Saved catalog.
3. **Weeks 3-5: biggest user value.** Photos.sqlite dates and GPS, WhatsApp and Messages context,
   Live Photo pairing, near-duplicate grouping.
4. **Weeks 5-6: distribution.** Hardened runtime, notarization, DMG, license notices.
5. **After that: recover more.** Images embedded in databases, KTX snapshots, deleted SQLite rows,
   `.ithmb` research.

---

## 12. Not verified in this review

- Core flows were reviewed from source; the photo-copy and full-backup paths were later exercised
  during recovery testing. Points still marked *inferred* or *not verified* (B5, B10) need checking
  on a device.
- Whether a notarized Developer ID build keeps the `temporary-exception.sbpl` rule hasn't been
  tested.
