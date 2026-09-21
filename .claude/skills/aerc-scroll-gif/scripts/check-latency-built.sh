#!/usr/bin/env bash
# The tap-latency gate against a FRESHLY BUILT aerc (the flake's attribute, not the deployed
# profile), so a craft run can go green before anything is switched. Exit code is
# record-scroll.sh's: 0 fast (median ≤ LAT_MAX), 1 sluggish, 2 laggy, 3 unmeasured/pipeline.
#   check-latency-built.sh [--out <dir>] [--surface aerc|plain]
set -uo pipefail
OUT=/home/eh/nix/.craft/scroll-latency-check; SURFACE=aerc
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; --surface) SURFACE="$2"; shift 2 ;; *) echo "unknown flag: $1" >&2; exit 3 ;; esac; done
mkdir -p /home/eh/nix/.craft/o-term-build
nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' -o /home/eh/nix/.craft/o-term-build/aerc-latency || exit 3
AERC=/home/eh/nix/.craft/o-term-build/aerc-latency/bin/aerc
echo "aerc under test: $(readlink -f "$AERC")"
exec bash "$(dirname "$(readlink -f "$0")")/record-scroll.sh" --input tap-latency --surface "$SURFACE" --aerc "$AERC" \
  --query 'from:arcteryx' --verdict-json --out "$OUT"
