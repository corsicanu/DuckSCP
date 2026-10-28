#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a release .app bundle into build/ and (with --install) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./branding.env
APP_VERSION="${APP_VERSION_OVERRIDE:-$APP_VERSION}" # tests build other versions
source scripts/signing_identity.sh
SCRATCH="${SCRATCH:-$HOME/Library/Caches/DuckSCP-build}"

swift build -c release --scratch-path "$SCRATCH" 2>&1 | grep -v "ld: warning: search path"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/DuckSCP"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# App icon from branding/AppIcon.iconset (regenerate with tools/make_icon.py).
iconutil -c icns branding/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# GPL and the licenses of statically linked libraries travel with the binary.
mkdir -p "$APP/Contents/Resources/licenses"
cp LICENSE THIRD_PARTY_NOTICES.md licenses/*.txt "$APP/Contents/Resources/licenses/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 0)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>DuckUpdateRepo</key><string>${UPDATE_REPO:-}</string>
  <key>LegacyAppName</key><string>${LEGACY_APP_NAME:-}</string>
  <key>LegacyBundleID</key><string>${LEGACY_BUNDLE_ID:-}</string>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Hardened runtime. With a stable identity (self-signed or Developer ID) macOS sees every
# version as the same app, so Keychain items stay readable without prompts after updates.
xattr -cr "$APP"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  # Remove a copy installed under the previous product name.
  [[ -n "${LEGACY_APP_NAME:-}" ]] && rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/$APP_NAME.app"
fi
