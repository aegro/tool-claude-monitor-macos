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
# O grep é só pra filtrar ruído do output — não pode ser ele quem decide se o build passou.
# Sem isolar o status: quando o grep -v filtra 100% das linhas (comum num build limpo), ele
# sai com status 1 (nenhuma linha selecionada) e o "|| true" mascara isso, mas também mascara
# uma falha real do swift build — que aí passaria batido pro binário .build/release/
# MonitorClaude ANTIGO (de um build anterior bem-sucedido) e ele seria assinado e instalado
# como se fosse novo, sem esse script nunca acusar erro.
set +e
swift build -c release 2>&1 | grep -Ev "^\[|^Building|^Compiling|warning:"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
[ "$BUILD_STATUS" -eq 0 ] || { echo "falhou: swift build (status $BUILD_STATUS)"; exit 1; }

BIN=".build/release/MonitorClaude"
[ -f "$BIN" ] || { echo "falhou: binário não gerado"; exit 1; }

# Monta e assina num stage temporário — só mexe em $APP depois do codesign dar certo, senão
# uma falha de assinatura apaga o app instalado e deixa o destino pela metade ou sem assinar.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/$(basename "$APP")"

echo "· montando $APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/MonitorClaude"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
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
if ! codesign --force --sign "$IDENTITY" "$STAGED_APP"; then
  echo "falhou: identidade \"$IDENTITY\" não encontrada ou recusada."
  echo "Crie uma vez no Acesso às Chaves: Assistente de Certificado → Criar um Certificado…"
  echo "  nome \"$IDENTITY\" · Raiz autoassinada · tipo Assinatura de código."
  echo "Ou aponte outra identidade: IDENTITY=\"…\" ./scripts/build.sh"
  exit 1
fi
xattr -cr "$STAGED_APP" 2>/dev/null || true

# Troca pelo app novo sem nunca deixar o destino sem um .app válido: o app atual só sai do
# caminho via rename (mesmo diretório = mesmo volume = atômico, não fica pela metade), e só
# depois de o STAGED_APP já assinado estar pronto pra entrar no lugar. Se o mv final falhar
# (ex.: STAGE em outro volume, disco cheio), a versão anterior volta ao lugar.
mkdir -p "$(dirname "$APP")"
BACKUP="$APP.prev.$$"
[ -e "$APP" ] && mv "$APP" "$BACKUP"
if mv "$STAGED_APP" "$APP"; then
  rm -rf "$BACKUP" 2>/dev/null || true
else
  echo "falhou: não consegui instalar em $APP."
  rm -rf "$APP"
  if [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$APP"
    echo "versão anterior restaurada."
  fi
  exit 1
fi

echo "· pronto: $APP"
