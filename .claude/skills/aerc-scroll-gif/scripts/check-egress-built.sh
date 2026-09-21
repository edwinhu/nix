#!/usr/bin/env bash
# The egress gate against a FRESHLY BUILT aerc: do `o`'s kitty frames reach the host as t=f/t=s
# file references (< 1 KB per frame) or as inline pixels? Exit code is record-scroll.sh's:
# 0 file-media, 2 inline-pixels, 3 unmeasured/pipeline.
#   check-egress-built.sh [--out <dir>]
set -uo pipefail
OUT=/home/eh/nix/.craft/scroll-egress-check
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; *) echo "unknown flag: $1" >&2; exit 3 ;; esac; done
mkdir -p /home/eh/nix/.craft/o-term-build
nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' -o /home/eh/nix/.craft/o-term-build/aerc-egress || exit 3
AERC=/home/eh/nix/.craft/o-term-build/aerc-egress/bin/aerc
echo "aerc under test: $(readlink -f "$AERC")"
exec bash "$(dirname "$(readlink -f "$0")")/record-scroll.sh" --input egress --surface aerc --aerc "$AERC" \
  --query 'from:arcteryx' --verdict-json --out "$OUT"
