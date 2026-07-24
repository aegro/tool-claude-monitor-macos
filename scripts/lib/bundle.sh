#!/bin/bash
# Montagem compartilhada do bundle "Monitor Claude.app". Sourced por:
#   scripts/build.sh   — build de desenvolvimento, identidade local autoassinada, instala em /Applications
#   scripts/release.sh — assinatura Developer ID + notarização para distribuição
# Fonte única do layout do bundle e do Info.plist para que build de dev e de release não
# possam divergir: um CFBundleIdentifier diferente muda o designated requirement e faria
# o macOS re-perguntar no Keychain — exatamente o que a assinatura pretende matar.

BUNDLE_ID="com.aegro.monitor-claude"

# assemble_bundle <binario> <app_path> <versao>
# (Re)cria um .app NÃO assinado em <app_path>. Quem chama assina depois.
assemble_bundle() {
  local bin="$1" app="$2" version="$3"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/MonitorClaude"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Monitor Claude</string>
  <key>CFBundleDisplayName</key><string>Monitor Claude</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MonitorClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Aegro · Monitor Claude</string>
</dict>
</plist>
PLIST
}
