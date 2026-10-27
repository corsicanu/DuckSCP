#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a release of DuckSCP into dist/: a drag-to-Applications .dmg, a .zip,
# and SHA-256 checksums. Usage: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./branding.env

scripts/build_app.sh
# Package from a clean copy outside the repo: ~/Desktop may attach Finder metadata
# that code signing rejects. The copy is re-signed (ad hoc, hardened runtime).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto --norsrc --noextattr --noqtn "build/$APP_NAME.app" "$WORK/$APP_NAME.app"
APP="$WORK/$APP_NAME.app"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" | tr ' ' '-')"
BASE="$APP_NAME-$APP_VERSION-macOS-$ARCH"
DIST="dist"
rm -rf "${DIST:?}"
mkdir -p "$DIST"
codesign --verify --deep --strict "$APP"

# Disk image: the app plus an Applications shortcut to drag it onto.
# Staged in the temp folder too, so no Finder metadata ends up in the image.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
hdiutil create -quiet -volname "$APP_NAME $APP_VERSION" -srcfolder "$STAGE" -ov -format UDZO "$WORK/$BASE.dmg"
mv "$WORK/$BASE.dmg" "$DIST/"

# Zip (keeps the bundle's signature and symlinks intact).
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$DIST/$BASE.zip"

(cd "$DIST" && shasum -a 256 "$BASE.dmg" "$BASE.zip" > SHA256SUMS.txt)
# Verify what users will download: the app inside the image and the zip must pass strict checks.
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DIST/$BASE.dmg"
codesign --verify --deep --strict "$MNT/$APP_NAME.app"
hdiutil detach -quiet "$MNT"
mkdir -p "$WORK/unzip"
ditto -x -k "$DIST/$BASE.zip" "$WORK/unzip"
codesign --verify --deep --strict "$WORK/unzip/$APP_NAME.app"
echo "Signatures verified (dmg and zip)."
echo "Packaged:"
ls -lh "$DIST"
