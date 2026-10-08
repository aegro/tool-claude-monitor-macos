#!/usr/bin/env bash
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir_bin="${CLAUDE_AUTO_DIR_BIN:-$HOME/.local/bin}"
mkdir -p "$dir_bin"
chmod +x "$raiz"/bin/*
for comando in claude-auto claude-accounts; do
  ln -sfn "$raiz/bin/$comando" "$dir_bin/$comando"
done
echo "claude-auto and claude-accounts linked in $dir_bin"
