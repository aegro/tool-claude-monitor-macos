#!/bin/bash
# Builds Monitor Claude.app and installs it. Signed with a stable local identity
# (IDENTITY, default "Aegro Local Dev") so the "Always Allow" ACL on the
# "Claude Code-credentials" keychain item survives rebuilds — ad-hoc signing has no
# durable identity, so macOS re-prompts on every build and, often, on every read.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-/Applications/Monitor Claude.app}"
VERSION="0.1.0"
IDENTITY="${IDENTITY:-Aegro Local Dev}"

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

echo "· assinando ($IDENTITY)"
if ! codesign --force --sign "$IDENTITY" "$APP"; then
  echo "falhou: identidade \"$IDENTITY\" não encontrada ou recusada."
  echo "Crie uma vez no Acesso às Chaves: Assistente de Certificado → Criar um Certificado…"
  echo "  nome \"$IDENTITY\" · Raiz autoassinada · tipo Assinatura de código."
  echo "Ou aponte outra identidade: IDENTITY=\"…\" ./scripts/build.sh"
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true

echo "· pronto: $APP"
