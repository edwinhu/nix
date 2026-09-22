#!/usr/bin/env bash
# GATE: wheel scrolling in the o viewer is eased in the page AND emitted at full rate.
#
# This replaces a held-arrow frame count as the smoothness gate. Holding an arrow measures the
# PAGER, which aerc-pager-keys.js deliberately makes discrete (scrollBy instant + preventDefault),
# so its frame count is low by design and says nothing about the wheel. Measured 2026-09-21:
#   held arrow, aerc o              14-27 changed frames / 3 s   <- by design, not a defect
#   wheel, no preload                1 scroll position per tick  <- the coarse 120px Linux detent
#   wheel, with preload            11 scroll positions per tick, RAF 60 fps
#   frames terminal-browser emits  60.3 per second during that   <- nothing coalesces upstream
#
# Two clauses, each failing on its own terms:
#   EASING  the median wheel tick spreads over >= MIN_STEPS scroll positions (the preload working)
#   EMIT    terminal-browser writes >= MIN_EMIT_FPS a=T frames per second while that happens
# A regression in either is what actually costs smoothness -- the inline frame transport shipped on
# 2026-09-21 would fail EMIT, which is the regression this gate exists to catch.
#
# Exit 0 both met, 1 a clause failed, 3 could-not-run.
set -uo pipefail

MIN_STEPS=${MIN_STEPS:-4}
# A RATIO, not a rate. An absolute frames/s here measured wheel-probe.ts, not the product: the
# driver paces ticks at a fixed rate and each yields MIN_STEPS-odd scroll positions, so the emit
# rate sat at 29/s whether 8, 24 or 48 ticks were sent (89/265/529 positions -> 91/268/538 frames,
# measured 2026-09-22) and the old target of 45 frames/s was unreachable by construction -- a gate
# that could not pass however good the pipeline was. What it was reaching for is that NO scroll
# position goes unpainted, and that is the ratio below.
MIN_EMIT_RATIO=${MIN_EMIT_RATIO:-0.95}
TICKS=${TICKS:-8}
SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
HERDR=$(command -v herdr || echo /home/eh/.local/share/mise/installs/herdr/latest/herdr)
[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }
command -v bun >/dev/null || { echo "bun is required for the cdp probe" >&2; exit 3; }

WORK=$(mktemp -d); PANE=""
cleanup() {
  [ -n "$PANE" ] && timeout 30 "$HERDR" pane close "$PANE" >/dev/null 2>&1
  timeout 30 "$TB" shutdown >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# A page tall enough that eight detents never reach the bottom, where scrolling legitimately stops.
python3 - "$WORK/page.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:24px">wheel gate line {i}</p>' for i in range(600))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY

# The launcher's own preload, so the gate measures what ships rather than a copy.
LAUNCHER=$(readlink -f "$HOME/.nix-profile/bin/aerc-mail-tty" 2>/dev/null)
PRELOAD=$(grep -oE "/nix/store/[^ \"]+aerc-pager-keys(-fps)?\.js" "$LAUNCHER" 2>/dev/null | head -1)
[ -n "${PRELOAD:-}" ] || { echo "could not find the pager-keys preload in $LAUNCHER" >&2; exit 3; }

STRACE=$(ls -d /nix/store/*-strace-[0-9]*/bin/strace 2>/dev/null | head -1)
[ -x "${STRACE:-/nonexistent}" ] || { echo "strace unavailable; cannot count emitted frames" >&2; exit 3; }

# The pane's shell inherits the herdr SERVER's environment, not this script's, so anything the
# browser must see has to be written into the launcher. FRAME_BUDGET is the addon's own bandwidth
# throttle and is the first thing to vary when EMIT comes in under the page's rAF rate.
cat > "$WORK/run.sh" <<EOF
#!/usr/bin/env bash
${TERMINAL_BROWSER_FRAME_BUDGET_MBPS:+export TERMINAL_BROWSER_FRAME_BUDGET_MBPS=$TERMINAL_BROWSER_FRAME_BUDGET_MBPS}
${TERMINAL_BROWSER_FRAMES:+export TERMINAL_BROWSER_FRAMES=$TERMINAL_BROWSER_FRAMES}
exec $STRACE -f -o $WORK/trace.txt -e trace=write -s 60 "$TB" open file://$WORK/page.html --preload=$PRELOAD
EOF
chmod +x "$WORK/run.sh"

# Own the daemon: the transport and the preload are fixed when it starts, and it is shared.
timeout 30 "$TB" shutdown >/dev/null 2>&1
PANE=$(timeout 30 "$HERDR" pane split --pane "${HERDR_PANE_ID:-}" --direction down --ratio 0.4 --no-focus 2>/dev/null \
  | grep -v "^mise " | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])" 2>/dev/null)
[ -n "${PANE:-}" ] || { echo "could not split a pane to host the probe browser" >&2; exit 3; }
# A short command: a long one typed into a pane arrives mangled.
timeout 30 "$HERDR" pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

for _ in $(seq 1 25); do
  PORT=$(timeout 20 "$TB" ls --json 2>/dev/null \
    | python3 -c "import sys,json; b=json.load(sys.stdin).get('browsers',[]); print(b[0]['cdpPort'] if b else '')" 2>/dev/null)
  [ -n "${PORT:-}" ] && break
  sleep 1
done
[ -n "${PORT:-}" ] || { echo "the probe browser never registered a cdp port" >&2; exit 3; }

BEFORE=$(grep -c "a=T" "$WORK/trace.txt" 2>/dev/null || echo 0)
T0=$(date +%s.%N)
OUT=$(timeout 200 bun "$SCRIPTS/wheel-probe.ts" --ticks "$TICKS" --port "$PORT" --min-steps "$MIN_STEPS" 2>&1)
RC=$?
T1=$(date +%s.%N)
AFTER=$(grep -c "a=T" "$WORK/trace.txt" 2>/dev/null || echo 0)
printf '%s\n' "$OUT"

[ "$RC" -le 1 ] || { echo "the wheel probe could not run" >&2; exit 3; }
STEPS=$(printf '%s' "$OUT" | grep -oE "median positions per tick: [0-9]+" | grep -oE "[0-9]+$")
[ -n "${STEPS:-}" ] || { echo "the wheel probe reported no median" >&2; exit 3; }

EMIT=$((AFTER - BEFORE))
POSITIONS=$(printf '%s' "$OUT" | grep -oE "over [0-9]+ distinct positions" | grep -oE "[0-9]+")
[ -n "${POSITIONS:-}" ] && [ "$POSITIONS" -gt 0 ] || { echo "the wheel probe reported no distinct positions" >&2; exit 3; }
RATIO=$(awk -v e="$EMIT" -v p="$POSITIONS" 'BEGIN{printf "%.3f", e/p}')
FPS=$(awk -v e="$EMIT" -v a="$T0" -v b="$T1" 'BEGIN{d=b-a; printf "%.1f", (d>0)? e/d : 0}')
echo "emitted $EMIT a=T frames for $POSITIONS scroll positions = $RATIO frames/position (target >= $MIN_EMIT_RATIO); $FPS frames/s is the DRIVER's pace, not a verdict"

FAIL=0
[ "$STEPS" -ge "$MIN_STEPS" ] || { echo "EASING unmet: $STEPS positions per tick, want >= $MIN_STEPS" >&2; FAIL=1; }
awk -v r="$RATIO" -v m="$MIN_EMIT_RATIO" 'BEGIN{exit !(r+0 >= m+0)}' \
  || { echo "EMIT unmet: $RATIO frames per scroll position, want >= $MIN_EMIT_RATIO -- positions are going unpainted" >&2; FAIL=1; }
[ "$FAIL" -eq 0 ] && { echo "wheel smoothness: EASING $STEPS positions/tick, EMIT $RATIO frames/position -- both met"; exit 0; }
exit 1
