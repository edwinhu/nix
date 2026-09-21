#!/usr/bin/env bash
# The herdr-surface gate against a FRESHLY BUILT aerc, in the DEDICATED herdr test session
# (desktop.sh: fork-built client — the stock 0.9.0 client inlines every frame into ghostty and
# holds key repeats behind those writes; fixed upstream in herdr PR #3957). aerc runs in a test
# pane under strace; the trace gives the ↓ cadence reaching the child and the egress capture the
# a=T escapes on the pty (the herdr sink must leave that at 0). Keys reach the test window by
# send_shortcut: the user's focus and session are never touched.
# Exit: 0 even and no pty frames, 4 bunched keys or frames on the pty, 3 unmeasured.
#   check-herdr-keys-built.sh [--out <dir>] [--min-keys N] [--max-gap-ms N]
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/desktop.sh"
OUT=/home/eh/nix/.craft/herdr-keys-check; MIN_KEYS=60; MAX_GAP=300
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; --min-keys) MIN_KEYS="$2"; shift 2 ;; --max-gap-ms) MAX_GAP="$2"; shift 2 ;; *) echo "unknown flag: $1" >&2; exit 3 ;; esac; done
mkdir -p "$OUT" /home/eh/nix/.craft/o-term-build
nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' -o /home/eh/nix/.craft/o-term-build/aerc-herdr || exit 3
AERC=$(readlink -f /home/eh/nix/.craft/o-term-build/aerc-herdr)/bin/aerc
echo "aerc under test: $AERC"
# Resolve strace ONCE here: `nix shell` inside the pane re-evaluates nixpkgs on every start and
# took longer than the 20 s the harness allows aerc to show its UI (round 1 of run -3).
STRACE=$(nix build 'nixpkgs#strace' --print-out-paths --no-link 2>/dev/null)/bin/strace
[ -x "$STRACE" ] || STRACE=$(ls -d /nix/store/*-strace-[0-9]*/bin/strace 2>/dev/null | head -1)   # the runner's env may lack the flake registry; an earlier build is in the store
[ -x "${STRACE:-/nonexistent}" ] || { echo "unmeasured: strace unavailable (nix build nixpkgs#strace failed and none in the store)" >&2; exit 3; }
echo "strace: $STRACE"
# The test pane's shell inherits nothing from here, so the wrapper carries literal paths.
W="$OUT/aerc-strace.sh"; rm -f "$OUT/trace.txt"
printf '%s\n' '#!/usr/bin/env bash' \
  "exec $STRACE -f -o $OUT/trace.txt -e trace=read,write -s 300 -tt $AERC \"\$@\"" > "$W"
chmod +x "$W"
bash "$(dirname "$(readlink -f "$0")")/record-scroll.sh" --input egress --surface aerc --aerc "$W" \
  --query 'from:arcteryx' --no-review --verdict-json --out "$OUT" | grep -E 'a=T|verdict|FAILED|test session'
[ -s "$OUT/trace.txt" ] || { echo "unmeasured: no strace trace written" >&2; exit 3; }
python3 "$(dirname "$(readlink -f "$0")")/judge-herdr-keys.py" "$OUT/trace.txt" "$OUT/verdict.json" "$MIN_KEYS" "$MAX_GAP"
