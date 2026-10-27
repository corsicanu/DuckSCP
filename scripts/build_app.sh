#!/bin/zsh
# Builds a release .app bundle into build/ and (with --install) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./branding.env
SCRATCH="${SCRATCH:-$HOME/Library/Caches/MacSCP-build}"

swift build -c release --scratch-path "$SCRATCH" 2>&1 | grep -v "ld: warning: search path"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/MacSCP"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

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
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Ad-hoc signature with the hardened runtime; a Developer ID goes here for public releases.
xattr -cr "$APP"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/$APP_NAME.app"
fi
