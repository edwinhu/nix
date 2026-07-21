#!/usr/bin/env bash
# install-guest-fonts.sh — push the Windows-compatible Latin Modern set into a
# running Word guest and register it.
#
#   WINVM_SSH=word@winvm ./install-guest-fonts.sh
#
# The fonts themselves are BUILT BY NIX (see word-render.nix -> mk_winfonts.py)
# and land at ~/.local/share/word-render/fonts. This script only transports and
# registers them; rebuild them with `nix run .#build-switch`, not by hand.
#
# Why this exists at all: a docx whose theme asks for "Latin Modern Roman" comes
# out of the guest in Cambria/Calibri unless BOTH of these hold —
#   1. the font is glyf-flavoured (TTF). Word lists CFF/OTF families in
#      Application.FontNames but silently substitutes on export; and
#   2. the family is in name ID 1. Stock Latin Modern puts the optical size
#      there ("LM Roman 10") and only sets the typographic family in ID 16,
#      which Word does not match on.
# mk_winfonts.py fixes both. See ../README.md.
set -euo pipefail

: "${WINVM_SSH:=word@winvm}"
FONTS="${WINVM_FONTS_DIR:-$HOME/.local/share/word-render/fonts}"
GUEST_DIR='C:/Users/word/lm-winfonts'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$FONTS" ] || { echo "no font dir at $FONTS — run the nix build first" >&2; exit 1; }
count=$(find "$FONTS" -name '*.ttf' | wc -l)
[ "$count" -gt 0 ] || { echo "no .ttf in $FONTS" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tar czf "$tmp/lm-winfonts.tgz" -C "$FONTS" .

ssh "$WINVM_SSH" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$GUEST_DIR' | Out-Null\""
scp -q "$tmp/lm-winfonts.tgz" "$WINVM_SSH:$GUEST_DIR/"
scp -q "$HERE/install-guest-fonts.ps1" "$WINVM_SSH:C:/Users/word/"

# Font install needs elevation; plain ssh already runs as the local admin `word`.
ssh "$WINVM_SSH" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\word\install-guest-fonts.ps1'

echo "installed $count Latin Modern faces into $WINVM_SSH"
echo "verify:  word-render <some.docx> out.pdf && pdffonts out.pdf   # expect LMRoman10-*"
