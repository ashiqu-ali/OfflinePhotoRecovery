# Third-party notices

The [MIT license](LICENSE) covers this project's own code. The built app also ships the
libraries and command-line tools below, each under its own license. `MacApp/build.sh` copies
their license files into the app at `Contents/Resources/ThirdPartyLicenses/`, together with
`VERSIONS.txt`, which records the exact versions that went into that build. Keep those files
with the app if you distribute it.

| Component | What the app uses | License | Source |
|---|---|---|---|
| libimobiledevice | the library, plus the `idevice_id`, `ideviceinfo`, `idevicepair`, `idevicebackup2` and `afcclient` tools | LGPL-2.1-or-later (its README states this for both the library and the utilities) | https://github.com/libimobiledevice/libimobiledevice |
| libimobiledevice-glue | the library | LGPL-2.1-or-later | https://github.com/libimobiledevice/libimobiledevice-glue |
| libusbmuxd | the library only (`libusbmuxd-2.0`) | Homebrew lists the package as GPL-2.0-or-later AND LGPL-2.1-or-later; the license file installed with the library the app ships is the LGPL-2.1 | https://github.com/libimobiledevice/libusbmuxd |
| libplist | the library | LGPL-2.1-or-later | https://github.com/libimobiledevice/libplist |
| OpenSSL 3 | `libssl` and `libcrypto` (used by libimobiledevice) | Apache-2.0 | https://github.com/openssl/openssl |

## How the LGPL libraries are included

They are shipped unmodified, as separate dynamic libraries in `Contents/Frameworks`, and are not
compiled into the app's own executable, so each one can be replaced with another build of the
same library. Their source code, for the version listed in `VERSIONS.txt`, is available from the
links above (each project tags its releases).

## Everything else

- The app's own decryption uses Apple's CommonCrypto, and its database reading uses the SQLite
  library that ships with macOS. Both are part of macOS and are not bundled.
- The Python scripts in `Tools/` use only the Python standard library.
