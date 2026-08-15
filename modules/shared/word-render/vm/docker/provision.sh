#!/usr/bin/env bash
# Stage the dockur/windows guest kit and start the install.
#
# Idempotent: re-run after `omarchy-windows-vm install` (which overwrites the
# compose file) or after editing anything under oem/.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OEM_DIR="$HOME/.local/share/word-render/vm-docker/oem"
COMPOSE_DIR="$HOME/.config/windows"
PUBKEY="${WINVM_PUBKEY:-$HOME/.ssh/id_winvm.pub}"

[ -f "$PUBKEY" ] || { echo "no ssh public key at $PUBKEY (ssh-keygen -f ${PUBKEY%.pub})" >&2; exit 1; }

mkdir -p "$OEM_DIR" "$COMPOSE_DIR" "$HOME/.windows" "$HOME/Windows"

cp "$KIT_DIR/oem/install.bat" "$KIT_DIR/oem/setup.ps1" "$KIT_DIR/oem/office-config.xml" "$OEM_DIR/"
cp "$KIT_DIR/../../render_docx.ps1" "$OEM_DIR/render_docx.ps1"
cp "$PUBKEY" "$OEM_DIR/authorized_key.txt"
cp "$KIT_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"

echo "staged:"
echo "  oem     $OEM_DIR"
echo "  compose $COMPOSE_DIR/docker-compose.yml"
echo
echo "start it with:  docker compose -f $COMPOSE_DIR/docker-compose.yml up -d"
echo "watch install:  http://127.0.0.1:8006   (10-20 min, then Word via ODT)"
echo "then verify:    ssh winvm 'powershell -Command \"(New-Object -ComObject Word.Application).Version\"'"
