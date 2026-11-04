#!/bin/bash
# Copies libimobiledevice's command-line tools and the Homebrew libraries they need into an
# app bundle, then rewrites their library paths so the app needs nothing outside itself.
#
#   Scripts/bundle-libimobiledevice.sh "build/Offline Photo Finder.app"
set -euo pipefail

APP="$1"
BREW="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
HELPERS="$APP/Contents/Helpers"
LIBS="$APP/Contents/Frameworks"
TOOLS=(idevice_id ideviceinfo idevicepair idevicebackup2 afcclient)

for tool in "${TOOLS[@]}"; do
    if [ ! -x "$BREW/bin/$tool" ]; then
        echo "error: $tool not found. Install it once (needs internet): brew install libimobiledevice" >&2
        exit 1
    fi
done

mkdir -p "$HELPERS" "$LIBS"
deps_of() { otool -L "$1" | awk 'NR>1 {print $1}' | grep "^$BREW/" || true; }

queue=()
for tool in "${TOOLS[@]}"; do
    cp "$BREW/bin/$tool" "$HELPERS/$tool"
    chmod u+w "$HELPERS/$tool"
    queue+=("$HELPERS/$tool")
done

# Walk the dependency tree and copy every Homebrew library exactly once.
i=0
while [ $i -lt ${#queue[@]} ]; do
    file="${queue[$i]}"
    i=$((i + 1))
    for dep in $(deps_of "$file"); do
        name=$(basename "$dep")
        if [ ! -f "$LIBS/$name" ]; then
            cp "$dep" "$LIBS/$name"
            chmod u+w "$LIBS/$name"
            queue+=("$LIBS/$name")
        fi
    done
done

for file in "$LIBS"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null
done
for file in "$HELPERS"/* "$LIBS"/*.dylib; do
    for dep in $(deps_of "$file"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null
    done
done
for tool in "${TOOLS[@]}"; do
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS/$tool" 2>/dev/null
done

# install_name_tool invalidates signatures; re-sign libraries first, then the tools.
codesign --force --sign - "$LIBS"/*.dylib
codesign --force --sign - "$HELPERS"/*

if otool -L "$HELPERS"/* "$LIBS"/*.dylib | grep -q "$BREW/"; then
    echo "error: a bundled file still points into $BREW" >&2
    exit 1
fi
# The bundled libraries' own license files travel with the app, as the LGPL and Apache licenses
# require, along with the exact versions used (see THIRD_PARTY_NOTICES.md).
NOTICES="$APP/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$NOTICES"
: > "$NOTICES/VERSIONS.txt"
for formula in libimobiledevice libimobiledevice-glue libusbmuxd libplist openssl@3; do
    keg="$BREW/opt/$formula"
    mkdir -p "$NOTICES/$formula"
    for file in "$keg"/COPYING* "$keg"/LICENSE* "$keg"/AUTHORS*; do
        if [ -f "$file" ]; then cp "$file" "$NOTICES/$formula/"; fi
    done
    echo "$formula $(basename "$(cd "$keg" && pwd -P)")" >> "$NOTICES/VERSIONS.txt"
done

echo "Bundled ${#TOOLS[@]} libimobiledevice tools and $(ls "$LIBS" | wc -l | tr -d ' ') libraries, with their licenses."
