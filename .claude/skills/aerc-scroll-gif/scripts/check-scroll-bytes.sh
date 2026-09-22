#!/usr/bin/env bash
# GATE: a scroll must not push a full surface of pixels per frame.
#
# What is known (2026-09-21, measured not inferred): the page eases correctly at RAF 60 fps, and
# terminal-browser emits 58-82 kitty a=T frames per second during a wheel scroll. Each of those
# names a 2016x1944 RGBA frame -- 15.7 MB -- so a one-second scroll moves on the order of a
# GIGABYTE through the graphics path, for a page whose visible change is a few hundred pixels of
# translation. That is the defect: not the easing, not the pager, not aerc, and not a frame rate.
#
# This gate is deliberately NOT a screen-capture measurement. Every frames-on-glass number tonight
# was fixture-sensitive or decayed into could-not-run; bytes announced on the wire are neither.
# It reads the s= and v= fields of each transmit and multiplies by 4 (RGBA), so it measures what
# the pipeline was ASKED to move.
#
# Exit 0 met (under the budget), 1 unmet, 3 could-not-run.
#
# DO NOT REACH FOR A RENDER-SCALE KNOB. All five variables the daemon reads were measured on
# 2026-09-21 with arrival proven in /proc/<daemon>/environ, and every one is inert on announced
# bytes: RENDER_SCALE (0.5 and 1 alike -- it is on the RECORDING path, not the live transmit),
# DISPLAY_SCALE, SHM, and FPS, which bought 8% for a 4x frame-rate cut. See
# .craft/scrollmeasure/07-knob-sweep.md.
#
# WHAT THIS GATE IS ACTUALLY MEASURING -- corrected 2026-09-22, and the correction matters more
# than the number. These full-surface pty transmits are terminal-browser's FALLBACK path. It has a
# dedicated herdr transport (frames as files, damage rects, a 3-slot ACK window:
# engine/crates/pixel-core/src/herdr.rs in its source) which it abandons SILENTLY when herdr's
# pane.graphics.info omits file_frame_transport. On this host that field is absent, because herdr
# sets it only when direct_graphics_available is true, and the client handshake clears that for an
# ssh session (herdr src/client/handshake.rs:65-69). So this gate measures the degraded path, and
# the fix is to restore the fast one, not to shrink the fallback.
#
# An earlier version of this header claimed terminal-browser "ships here as a binary with no
# source". That was FALSE. It is MIT and public (github.com/zenbu-labs/terminal-browser); a clone
# of the exact installed tag is at .craft/tb-src, and the install ships sourcemaps with
# sourcesContent. Nothing here is unfixable for want of source.
set -uo pipefail

# The budget is a RATIO, not a byte rate: bytes scale with the surface and the scroll
# distance, so an absolute MB/s is unarmable on one pane and vacuous on another. Measured
# 2026-09-21: 518 MB announced for 25 ticks = 9.09x the DPR-corrected minimum, decomposed as
# 2.12x (frames per scroll position) times 4.95x (full surface where a damage rect would do).
# 3x leaves room for the one-frame allowance and a little per-position overlap.
MAX_AMPLIFICATION=${SCROLL_MAX_AMPLIFICATION:-3}
TICKS=${TICKS:-20}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts
HERDR=$(command -v herdr || echo /home/eh/.local/share/mise/installs/herdr/latest/herdr)

[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }
command -v bun >/dev/null || { echo "bun is required for the cdp wheel driver" >&2; exit 3; }
S=$(ls -d /nix/store/*-strace-[0-9]*/bin/strace 2>/dev/null | head -1)
[ -x "${S:-/nonexistent}" ] || { echo "strace unavailable" >&2; exit 3; }
[ -n "${HERDR_PANE_ID:-}" ] || { echo "no HERDR_PANE_ID: this gate needs a herdr pane to split" >&2; exit 3; }

WORK=$(mktemp -d); PANE=""

# A PRIVATE DAEMON. The socket is $XDG_RUNTIME_DIR/terminal-browser/daemon.sock, so relocating that
# one variable gives this gate a daemon nobody else can serve and it need not kill anyone else's.
# Without it the gate had to seize the SHARED daemon: destructive to the user's open pages, and
# corruptible by any other process that raced one up -- which is what exit 3 caught on 2026-09-21.
# The rest of the real runtime dir is symlinked through, so the wayland socket stays reachable.
PRIV="$WORK/xdg"
mkdir -p "$PRIV/terminal-browser"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  for e in "$XDG_RUNTIME_DIR"/*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in terminal-browser) continue ;; esac
    ln -sfn "$e" "$PRIV/${e##*/}" 2>/dev/null
  done
fi
tb() { env XDG_RUNTIME_DIR="$PRIV" timeout 20 "$TB" "$@"; }

cleanup() {
  [ -n "${PANE:-}" ] && timeout 20 "$HERDR" pane close "$PANE" >/dev/null 2>&1
  tb shutdown >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

python3 - "$WORK/tall.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">scroll byte budget line {i}</p>' for i in range(800))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY

# Own the daemon outright: private socket, so this is ours and only ours.
tb shutdown >/dev/null 2>&1
# The pane inherits the herdr SERVER's environment, not this script's, so anything the browser must
# see has to be written into the launcher. SCROLL_ENV carries experiments: SCROLL_ENV="GDK_SCALE=1"
cat > "$WORK/run.sh" <<EOF
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=$PRIV
${SCROLL_ENV:+export $SCROLL_ENV}
exec $S -f -o $WORK/trace.txt -e trace=write -s 80 "$TB" open file://$WORK/tall.html
EOF
chmod +x "$WORK/run.sh"

PANE=$(timeout 30 "$HERDR" pane split --pane "$HERDR_PANE_ID" --direction down --ratio 0.35 --no-focus 2>/dev/null \
  | grep -v "^mise " | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])" 2>/dev/null)
[ -n "${PANE:-}" ] || { echo "could not split a pane" >&2; exit 3; }
timeout 30 "$HERDR" pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

for _ in $(seq 1 30); do
  PORT=$(tb ls --json 2>/dev/null \
    | python3 -c "import sys,json; b=json.load(sys.stdin).get('browsers',[]); print(b[0]['cdpPort'] if b else '')" 2>/dev/null)
  [ -n "${PORT:-}" ] && break
  sleep 1
done
[ -n "${PORT:-}" ] || { echo "the browser never registered a cdp port" >&2; exit 3; }

# PROVE THE ENV REACHED THE DAEMON. browserRenderScale() and the frame-transport probe both run in
# the daemon, which the CLI spawns with its own process.env -- but `shutdown` is not instantaneous,
# so a leftover daemon silently serves the request with the OLD environment and the measurement
# reports the default while looking like a verdict. That produced three identical readings on
# 2026-09-21 and nearly a false "this knob is inert". Exit 3 rather than measure the wrong thing.
if [ -n "${SCROLL_ENV:-}" ]; then
  # Match on OUR private runtime dir. A cmdline pattern cannot tell our daemon from another
  # process's, and "terminal-browser" appears in the command line of anything MEASURING it.
  DPID=""
  for c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
    pid=${c#/proc/}; pid=${pid%/environ}
    grep -qa "electron" /proc/"$pid"/cmdline 2>/dev/null || continue
    DPID=$pid; break
  done
  [ -n "${DPID:-}" ] || { echo "no daemon of our own to verify the environment on" >&2; exit 3; }
  for kv in $SCROLL_ENV; do
    k=${kv%%=*}
    if ! tr '\0' '\n' < /proc/"$DPID"/environ 2>/dev/null | grep -qx "$kv"; then
      echo "SCROLL_ENV asked for $kv but the daemon (pid $DPID) does not carry it:" >&2
      tr '\0' '\n' < /proc/"$DPID"/environ 2>/dev/null | grep "^$k=" >&2 || echo "  ($k unset in the daemon)" >&2
      echo "  a stale daemon is serving this measurement; it would report the DEFAULT" >&2
      exit 3
    fi
  done
  echo "verified in daemon $DPID: $SCROLL_ENV"
fi
sleep 4

# grep -c EXITS 1 when the count is zero while still printing 0, so `|| echo 0` appended a second
# line and the python arg became "0\n0". Zero is the expected count once the direct-kitty file
# transport is live, so the failure mode was reachable only on a WORKING pipeline.
BEFORE=$(grep -c "a=T" "$WORK/trace.txt" 2>/dev/null); BEFORE=${BEFORE:-0}
T0=$(date +%s.%N)
timeout 120 bun "$SCRIPTS/wheel-probe.ts" --ticks "$TICKS" --gap 50 --port "$PORT" > "$WORK/wheel.txt" 2>&1
RC=$?
T1=$(date +%s.%N)
[ "$RC" -le 1 ] || { echo "the wheel driver could not run" >&2; sed -n 1,3p "$WORK/wheel.txt" >&2; exit 3; }

SCROLLED=$(grep -oE "scrolled [0-9]+px" "$WORK/wheel.txt" | grep -oE "[0-9]+" | tail -1)
[ -n "${SCROLLED:-}" ] || { echo "the wheel driver reported no scroll distance" >&2; exit 3; }

python3 - "$WORK/trace.txt" "$BEFORE" "$T0" "$T1" "$MAX_AMPLIFICATION" "$SCROLLED" <<'PY'
import re, sys
trace, before, t0, t1, budget, scrolled = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6])
seen = 0
px = 0
dims = None
for line in open(trace, errors="replace"):
    if "a=T" not in line:
        continue
    seen += 1
    if seen <= before:
        continue
    m = re.search(r"s=(\d+),v=(\d+)", line)
    if m:
        w, h = int(m.group(1)), int(m.group(2))
        dims = (w, h)
        px += w * h * 4          # f=32 is RGBA
frames = max(0, seen - before)
secs = max(0.001, t1 - t0)
mb = px / 1048576
rate = mb / secs
if not dims or not frames:
    print("no full-surface transmits seen; cannot compute amplification")
    sys.exit(3)
w, h = dims
# What a damage-rect scheme would have had to send: the band of pixels that actually moved, at the
# surface's own scale, plus one full frame to establish the image.
dpr = h / 1188 if h else 1          # the surface is already in device px; keep the ratio explicit
minimum = w * scrolled * 4 + w * h * 4
amp = px / minimum if minimum else 0
print(f"{frames} full-surface transmits, {mb:.0f} MB announced in {secs:.2f}s ({rate:.0f} MB/s), surface {w}x{h}")
print(f"scrolled {scrolled}px; damage-rect minimum {minimum/1048576:.0f} MB; amplification {amp:.2f}x, budget {budget:.1f}x")
sys.exit(0 if amp <= budget else 1)
PY
