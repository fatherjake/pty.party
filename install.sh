#!/bin/bash
# Build pty.party and install it as a proper .app bundle in ~/Applications.
# Usage: ./install.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
EXEC_NAME="ptyparty"            # SwiftPM product / executable name
DISPLAY_NAME="pty.party"       # user-facing app name
BUNDLE_ID="co.uk.jacobford.ptyparty"
DEST="$HOME/Applications/$DISPLAY_NAME.app"

echo "Building $DISPLAY_NAME ($CONFIG)..."
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "Assembling $DEST..."
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/$EXEC_NAME"
cp "icon/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>0.3.0</string>
    <key>CFBundleVersion</key>         <string>3</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS treats it as a stable app identity.
codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

echo "Installed $DISPLAY_NAME to $DEST"
echo "Launch with:  open \"$DEST\""
