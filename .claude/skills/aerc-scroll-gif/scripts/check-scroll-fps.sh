#!/usr/bin/env bash
# GATE: a sustained wheel scroll delivers frames to the herdr pane at ~60 per second.
#
# This is the number check-scroll-bytes.sh cannot see. That gate exits 0 on "zero pty transmits and
# the pane is on direct-kitty", which is equally true at 60 fps and at 3 fps: once frames travel as
# files nothing is announced on the pty, so the fallback's byte count goes to zero and the fast
# path's RATE is never counted.
#
# It counts frames ON THE WIRE rather than on the screen, because every screen-capture number here
# was fixture-sensitive: the ffprobe scene filter counts frames that differ MATERIALLY, so the page
# decides the answer. A frame on the direct path is one JSON header line written to herdr's socket
#   {"format":"rgba","image_width":..,"file":{"path":..},"sequence":..,..}
# (pixel-core/src/herdr.rs:126-135), so counting those writes counts frames handed over, exactly as
# check-scroll-bytes.sh counts a=T writes on the pty fallback. Both are counted here, because which
# path carried them is half the answer.
#
# TERMINAL_BROWSER_AUTOPROFILE_MS was tried first and abandoned: the spans exist in the shipped
# binary (herdr.handoff, herdr.ack) but `terminal-browser open` hands the page to a daemon and the
# recording lives on that daemon's engine thread, so no report ever reaches the caller's cwd.
#
# What the rate is up against, from the source: present() writes the FULL canvas into a ring slot
# (herdr.rs:145-163 -- not a damage rect) and then BLOCKS on read_line for herdr's ack
# (herdr.rs:137) before returning. Those two run in series per frame, so the path is capped at
# 1/(write+composite+ack) however fast the page paints.
#
# WHAT THIS MEASURES IS DELIVERY, NOT PAINT. It counts frames handed over. Whether herdr composites
# and ghostty draws them all is a different question and needs a different instrument.
#
# Exit 0 at or above the floor, 1 below it, 3 could-not-run.
set -uo pipefail

MIN_FPS=${SCROLL_MIN_FPS:-55}
# SATURATE, never pace. The browser emits ~1.2 frames per wheel tick, so a gap-paced driver makes
# the VERDICT a function of the gap: measured 2026-09-22, the same pipeline read 37 fps at gap 16,
# 24.5 at gap 33 and 60.2 at gap 8. Those numbers describe this script, not the product. Driven
# flat out the rate plateaus -- 61.0 / 60.7 / 60.8 fps at gaps 4, 1 and 0 -- and the plateau is the
# only figure that is the pipeline's own.
TICKS=${TICKS:-400}
GAP=${GAP:-0}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts
HERDR=$(command -v herdr || echo /home/eh/.local/share/mise/installs/herdr/latest/herdr)

[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }
command -v bun >/dev/null || { echo "bun is required for the cdp wheel driver" >&2; exit 3; }
S=$(ls -d /nix/store/*-strace-[0-9]*/bin/strace 2>/dev/null | head -1)
[ -x "${S:-/nonexistent}" ] || { echo "strace unavailable" >&2; exit 3; }
# TWO SERVERS, and which one is measured is the whole point of the flag. By default the gate
# splits a pane on the herdr the user is running, which is what the number has to be true of.
# SCROLL_TEST_HERDR_BIN measures a BUILD instead: desktop.sh brings up a dedicated session in its
# own ghostty window, on its own socket, so a server-side change can be measured without
# restarting the user's live server -- which no check here is allowed to do.
PARENT_PANE=""
if [ -n "${SCROLL_TEST_HERDR_BIN:-}" ]; then
  [ -x "$SCROLL_TEST_HERDR_BIN" ] || { echo "no herdr build at $SCROLL_TEST_HERDR_BIN" >&2; exit 3; }
  # desktop.sh borrows the compositor environment itself at source time.
  . "$(dirname "$(readlink -f "$0")")/desktop.sh"
  [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { echo "no compositor environment to borrow" >&2; exit 3; }
  TEST_HERDR_BIN="$SCROLL_TEST_HERDR_BIN"
  TEST_SESSION=${TEST_SESSION:-fpsgate}
  TEST_CLASS=${TEST_CLASS:-dev.fpsgate}
  TEST_SOCKET="$HOME/.config/herdr/sessions/$TEST_SESSION/herdr.sock"
  desktop_lock
  test_session_ensure || exit 3
  HERDR="$TEST_HERDR_BIN"
  export HERDR_SOCKET_PATH="$TEST_SOCKET"
  PARENT_PANE=$(h pane list 2>/dev/null | grep -v "^mise " \
    | python3 -c "import sys,json; p=json.load(sys.stdin)['result']['panes']; print(p[0]['pane_id'] if p else '')" 2>/dev/null)
  [ -n "${PARENT_PANE:-}" ] || { echo "the test session has no pane to split" >&2; exit 3; }
  echo "measuring the build at $SCROLL_TEST_HERDR_BIN (session $TEST_SESSION), not the live server" >&2
else
  [ -n "${HERDR_PANE_ID:-}" ] || { echo "no HERDR_PANE_ID: this gate needs a herdr pane to split" >&2; exit 3; }
  PARENT_PANE="$HERDR_PANE_ID"
fi

WORK=$(mktemp -d); PANE=""

# A PRIVATE DAEMON, as check-scroll-bytes.sh does: the socket lives under XDG_RUNTIME_DIR, so
# relocating that one variable gives this gate a daemon nobody else can serve and it need not kill
# the user's own browser. The rest of the runtime dir is symlinked so wayland stays reachable.
PRIV="$WORK/xdg"
mkdir -p "$PRIV/terminal-browser"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  for e in "$XDG_RUNTIME_DIR"/*; do
    [ -e "$e" ] || continue
    # The daemon socket dir is terminal-browser-<hash>/, NOT terminal-browser/ -- skipping only the
    # exact name symlinked the user's real daemon straight through, so the "private" daemon was
    # theirs and `shutdown` reached it. Skip the whole family.
    case "${e##*/}" in terminal-browser*) continue ;; esac
    ln -sfn "$e" "$PRIV/${e##*/}" 2>/dev/null
  done
fi
tb() { env XDG_RUNTIME_DIR="$PRIV" timeout 20 "$TB" "$@"; }

# KEEP_WORK=1 leaves the work dir and names it, for when the gate says could-not-run and the
# question is what the daemon actually did.
cleanup() {
  [ -n "${PANE:-}" ] && timeout 20 "$HERDR" pane close "$PANE" >/dev/null 2>&1
  # Our own daemon only, found by the private runtime dir it carries. NEVER `shutdown`: it ends
  # every terminal-browser daemon on the machine, closing whatever the user has open in the o viewer.
  for __c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$__c" 2>/dev/null || continue
    __p=${__c#/proc/}; __p=${__p%/environ}
    grep -qa "electron" /proc/"$__p"/cmdline 2>/dev/null && kill "$__p" 2>/dev/null
  done
  if [ -n "${KEEP_WORK:-}" ]; then echo "work dir kept: $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

python3 - "$WORK/tall.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">scroll fps line {i}</p>' for i in range(1200))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY


# The pane inherits the herdr SERVER's environment, not this script's, so anything the browser must
# see has to be written into the launcher. -f follows the daemon the CLI hands the page to, which is
# the process that actually writes frames.
cat > "$WORK/run.sh" <<EOF
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=$PRIV
${SCROLL_ENV:+export $SCROLL_ENV}
cd $WORK
exec $S -f -o $WORK/trace.txt -e trace=write -s 120 "$TB" open file://$WORK/tall.html
EOF
chmod +x "$WORK/run.sh"

PANE=$(timeout 30 "$HERDR" pane split --pane "$PARENT_PANE" --direction down --ratio 0.35 --no-focus 2>/dev/null \
  | grep -v "^mise " | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])" 2>/dev/null)
[ -n "${PANE:-}" ] || { echo "could not split a pane" >&2; exit 3; }
timeout 30 "$HERDR" pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

for _ in $(seq 1 30); do
  PORT=$(tb ls --json 2>/dev/null \
    | python3 -c "import sys,json; b=json.load(sys.stdin).get('browsers',[]); print(b[0]['cdpPort'] if b else '')" 2>/dev/null)
  [ -n "${PORT:-}" ] && break
  sleep 1
done
# `tb ls` asks the daemon, and in a dedicated test session the browser does not always register
# there -- but it always ANNOUNCES the port on stderr, which the strace log captured. The port is
# what the wheel driver needs; where the daemon filed it is not this gate's problem.
if [ -z "${PORT:-}" ]; then
  for _ in $(seq 1 20); do
    PORT=$(grep -oE 'DevTools listening on ws://127\.0\.0\.1:[0-9]+' "$WORK/trace.txt" 2>/dev/null \
      | grep -oE '[0-9]+$' | tail -1)
    [ -n "${PORT:-}" ] && break
    sleep 1
  done
  [ -n "${PORT:-}" ] && echo "note: cdp port $PORT read from the browser's own announcement, not the daemon" >&2
fi
[ -n "${PORT:-}" ] || { echo "the browser never registered or announced a cdp port" >&2; exit 3; }

# Which transport is this pane on? A rate measured on the pty fallback answers a different question,
# so say which path was timed rather than reporting a bare number.
TRANSPORT=$(python3 - "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" "$PANE" <<'PYX' 2>/dev/null || true
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5); s.connect(sys.argv[1])
    s.sendall((json.dumps({"id": "i", "method": "pane.graphics.info",
                           "params": {"pane_id": sys.argv[2]}}) + "\n").encode())
    b = b""
    while b"\n" not in b:
        d = s.recv(65536)
        if not d: break
        b += d
    print(json.loads(b.decode().split("\n")[0])["result"].get("file_frame_transport") or "")
except Exception:
    print("")
PYX
)

if [ -n "${SCROLL_ENV:-}" ]; then
  DPID=""
  for c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
    pid=${c#/proc/}; pid=${pid%/environ}
    grep -qa "electron" /proc/"$pid"/cmdline 2>/dev/null || continue
    DPID=$pid; break
  done
  [ -n "${DPID:-}" ] || { echo "no daemon of our own to verify the environment on" >&2; exit 3; }
  for kv in $SCROLL_ENV; do
    if ! tr '\0' '\n' < /proc/"$DPID"/environ 2>/dev/null | grep -qx "$kv"; then
      echo "SCROLL_ENV asked for $kv but the daemon (pid $DPID) does not carry it" >&2
      echo "  a stale daemon is serving this measurement; it would report the DEFAULT" >&2
      exit 3
    fi
  done
  echo "verified in daemon $DPID: $SCROLL_ENV" >&2
fi

sleep 2
# Frames already handed over before the wheel (the first paint) are not the scroll's, so count a
# baseline and measure the delta -- the same shape check-scroll-bytes.sh uses for a=T.
FB=$(grep -c '"format":"rgba"' "$WORK/trace.txt" 2>/dev/null); FB=${FB:-0}
PB=$(grep -c "a=T" "$WORK/trace.txt" 2>/dev/null); PB=${PB:-0}
T0=$(date +%s.%N)
timeout 120 bun "$SCRIPTS/wheel-probe.ts" --ticks "$TICKS" --gap "$GAP" --port "$PORT" > "$WORK/wheel.txt" 2>&1
RC=$?
T1=$(date +%s.%N)
[ "$RC" -le 1 ] || { echo "the wheel driver could not run" >&2; sed -n 1,3p "$WORK/wheel.txt" >&2; exit 3; }

python3 - "$WORK/trace.txt" "$FB" "$PB" "$T0" "$T1" "$MIN_FPS" "${TRANSPORT:-}" <<'VERDICT'
import sys
trace, fb, pb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
t0, t1, floor = float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
transport = sys.argv[7] if len(sys.argv) > 7 else ""

direct = pty = 0
for line in open(trace, errors="replace"):
    if chr(34) + "format" + chr(34) + ":" + chr(34) + "rgba" + chr(34) in line:
        direct += 1
    elif "a=T" in line:
        pty += 1
direct = max(0, direct - fb)
pty = max(0, pty - pb)
secs = max(0.001, t1 - t0)
frames = direct + pty
fps = frames / secs

if not frames:
    print(f"no frames were handed over during the {secs:.2f}s scroll (transport={transport or 'none'}).")
    print("Nothing painted, so there is no frame rate to report -- this measured nothing.")
    sys.exit(3)

path = "direct-kitty files" if direct and not pty else ("pty fallback" if pty and not direct else "both paths")
print(f"{frames} frames in {secs:.2f}s = {fps:.1f} fps (floor {floor:.0f}) over {path}")
print(f"  {direct} as herdr frame files, {pty} as full-surface pty transmits; pane reports file_frame_transport={transport or 'absent'}")
if fps < floor and direct:
    print(f"  {1000/fps:.1f} ms per frame on the direct path -- the serial write+ack round trip in herdr.rs:123-140 is the first thing to look at")
sys.exit(0 if fps >= floor else 1)
VERDICT
