#!/bin/bash
# Compila, assina (Developer ID), notariza e grampeia "Monitor Claude.app", e empacota
# num zip distribuível. Este é o caminho de RELEASE: o artefato assinado é o que todo
# usuário baixa, então um único "Sempre Permitir" na primeira execução gruda para sempre
# — o certificado Developer ID carrega um teamid estável que o macOS adiciona à partition
# list do item de Keychain. Build local de desenvolvimento continua em scripts/build.sh.
#
# Env obrigatório (o CI fornece via secrets do repo):
#   SIGN_IDENTITY   nome completo da identidade, ex.: "Developer ID Application: Aegro … (TEAMID)"
#   AC_APPLE_ID     Apple ID (e-mail) usado na notarização
#   AC_TEAM_ID      Team ID (10 chars) da conta Apple Developer
#   AC_PASSWORD     app-specific password dessa Apple ID
# Env opcional:
#   VERSION         default: a tag git (v1.2.3 -> 1.2.3); fora de tag, "0.0.0-dev"
#   OUTPUT_DIR      onde o zip final cai (default: dist/)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?defina SIGN_IDENTITY (Developer ID Application: … (TEAMID))}"
: "${AC_APPLE_ID:?defina AC_APPLE_ID (Apple ID da notarização)}"
: "${AC_TEAM_ID:?defina AC_TEAM_ID (Team ID Apple Developer)}"
: "${AC_PASSWORD:?defina AC_PASSWORD (app-specific password)}"

# Versão: VERSION do ambiente (o CI passa a tag via github.ref_name); senão a tag git
# do commit atual; fora de tag, um placeholder de dev. Tira o prefixo "v" em qualquer caso.
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git describe --tags --exact-match 2>/dev/null || echo 0.0.0-dev)"
fi
VERSION="${VERSION#v}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

echo "· compilando (release $VERSION)"
# Mesmo tratamento de status do build.sh: o grep só filtra ruído, quem decide é o PIPESTATUS
# do swift build — senão um build limpo (grep filtra tudo, sai 1) ou uma falha real passariam batidos.
set +e
swift build -c release 2>&1 | grep -Ev "^\[|^Building|^Compiling|warning:"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
[ "$BUILD_STATUS" -eq 0 ] || { echo "falhou: swift build (status $BUILD_STATUS)"; exit 1; }

BIN=".build/release/MonitorClaude"
[ -f "$BIN" ] || { echo "falhou: binário não gerado"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Monitor Claude.app"

echo "· montando bundle"
source scripts/lib/bundle.sh
assemble_bundle "$BIN" "$APP" "$VERSION"

echo "· assinando (Developer ID · hardened runtime)"
# --options runtime (hardened runtime) é exigido pela notarização; --timestamp pega um
# timestamp seguro pra assinatura seguir válida mesmo depois de o certificado expirar.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Notariza um zip do app e depois grampeia o ticket no próprio .app (não dá pra grampear
# um zip). O ditto --keepParent mantém o diretório .app dentro do arquivo.
ZIP_FOR_NOTARY="$WORK/notarize.zip"
echo "· zipando para notarização"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP_FOR_NOTARY"

echo "· notarizando (pode levar alguns minutos)"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
  --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD" \
  --wait

echo "· grampeando o ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Veredito do próprio Gatekeeper — deve dizer "accepted / source=Notarized Developer ID".
spctl --assess --type execute --verbose=4 "$APP" || true

mkdir -p "$OUTPUT_DIR"
OUT_ZIP="$OUTPUT_DIR/Monitor-Claude-$VERSION.zip"
rm -f "$OUT_ZIP"
echo "· empacotando release: $OUT_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT_ZIP"

echo "· pronto: $OUT_ZIP"
