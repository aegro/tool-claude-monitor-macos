#!/usr/bin/env bash
set -euo pipefail

# Roda a suíte de testes.
#
# Com Xcode instalado, `swift test` puro já resolve e é isso que o CI faz. Com apenas as
# Command Line Tools — que é o setup de quem só compila o app — o swift-testing vem como
# framework solto fora dos caminhos padrão: o compilador não enxerga o módulo `Testing` sem
# um `-F`, e o bundle de teste, já compilado, procura as bibliotecas por @rpath em diretórios
# que não existem. Os dois links abaixo plantam exatamente onde o bundle procura (dentro de
# .build, que é descartável), em vez de mexer em diretório de sistema.

cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVELOPER_DIR_PATH" == *.app/Contents/Developer ]]; then
    exec swift test "$@"
fi

CLT="${DEVELOPER_DIR_PATH:-/Library/Developer/CommandLineTools}"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
INTEROP="$CLT/Library/Developer/usr/lib/lib_TestingInterop.dylib"

if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
    echo "Testing.framework não encontrado em $FRAMEWORKS." >&2
    echo "Instale o Xcode ou atualize as Command Line Tools (xcode-select --install)." >&2
    exit 1
fi

swift build --build-tests -Xswiftc -F -Xswiftc "$FRAMEWORKS" "$@"

BUILD_DIR="$(swift build --show-bin-path -Xswiftc -F -Xswiftc "$FRAMEWORKS")"
ln -sfn "$FRAMEWORKS/Testing.framework" "$BUILD_DIR/Testing.framework"
[[ -f "$INTEROP" ]] && ln -sfn "$INTEROP" "$BUILD_DIR/$(basename "$INTEROP")"

exec swift test --skip-build -Xswiftc -F -Xswiftc "$FRAMEWORKS" "$@"
