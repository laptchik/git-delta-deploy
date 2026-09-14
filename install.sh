#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 1 ]]; then
  echo "Usage: ./install.sh [BIN_DIR]" >&2
  exit 2
fi

BIN_DIR="${1:-$HOME/.local/bin}"

install -d -- "$BIN_DIR"
install -m 0755 -- \
  "$SCRIPT_DIR/git-delta-deploy" \
  "$SCRIPT_DIR/git-delta-deploy-via-password" \
  "$BIN_DIR/"

echo "Installed git-delta-deploy and git-delta-deploy-via-password in $BIN_DIR"
