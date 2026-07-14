#!/bin/bash
# Builds Farol.app and installs it. Ad-hoc signed: the keychain ACL is bound to the
# code signature, so a rebuild re-prompts once for "Claude Code-credentials".
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-/Applications/Monitor Claude.app}"
VERSION="0.1.0"

echo "· compilando"
swift build -c release 2>&1 | grep -Ev "^\[|^Building|^Compiling|warning:" || true

BIN=".build/release/MonitorClaude"
[ -f "$BIN" ] || { echo "falhou: binário não gerado"; exit 1; }

echo "· montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MonitorClaude"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Monitor Claude</string>
  <key>CFBundleDisplayName</key><string>Monitor Claude</string>
  <key>CFBundleIdentifier</key><string>com.aegro.monitor-claude</string>
  <key>CFBundleExecutable</key><string>MonitorClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Aegro · Monitor Claude</string>
</dict>
</plist>
PLIST

echo "· assinando"
codesign --force --deep --sign - "$APP" 2>/dev/null
xattr -cr "$APP" 2>/dev/null || true

echo "· pronto: $APP"
