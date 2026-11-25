#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/build/NotchAI.app"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/notchai-build.XXXXXX")"
STAGED_APP="$STAGE/NotchAI.app"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "==> Building NotchAI ($CONFIG)"
swift build -c "$CONFIG" --product NotchAI
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling app bundle in $STAGE"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/NotchAI" "$STAGED_APP/Contents/MacOS/NotchAI"
chmod +x "$STAGED_APP/Contents/MacOS/NotchAI"

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>NotchAI</string>
    <key>CFBundleIdentifier</key>
    <string>com.aadithkannoth.NotchAI</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NotchAI</string>
    <key>CFBundleDisplayName</key>
    <string>NotchAI</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>NotchAI local build</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi

# The workspace lives under a File Provider-managed Documents folder; signing in place fails with
# "resource fork, Finder information, or similar detritus not allowed". Sign the staged copy in a
# plain temporary directory, then install the already-signed bundle.
xattr -cr "$STAGED_APP" 2>/dev/null || true

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -n "${IDENTITY}" ]]; then
  echo "==> Signing with Apple Development identity: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$STAGED_APP"
else
  echo "==> No Apple Development identity found; ad-hoc signing"
  codesign --force --sign - --timestamp=none "$STAGED_APP"
fi
codesign --verify --deep --strict --verbose=2 "$STAGED_APP" 2>&1 | tail -2

echo "==> Installing signed bundle into build/"
pkill -x NotchAI 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
mkdir -p "$ROOT/build"
ditto --norsrc --noextattr "$STAGED_APP" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2 || true

# The workspace under Documents is File Provider-managed and re-adds FinderInfo xattrs that make
# strict verification fail. Install the canonical, launchable copy into ~/Applications instead.
INSTALLED_APP="$HOME/Applications/NotchAI.app"
echo "==> Installing launchable app: $INSTALLED_APP"
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED_APP"
ditto --norsrc --noextattr "$STAGED_APP" "$INSTALLED_APP"
xattr -cr "$INSTALLED_APP" 2>/dev/null || true
codesign --verify --strict --verbose=2 "$INSTALLED_APP" 2>&1 | tail -2
echo "==> Done: $INSTALLED_APP (build artifact: $APP)"
