#!/usr/bin/env bash
# GATE: herdr paints terminal-browser frames at something near what ghostty alone manages.
#
# Measured 2026-09-21, same page, same recorder, same region, same full-viewport delta -- the only
# variable being whether herdr sits between the browser and the terminal:
#   ghostty alone, no herdr   59 changed frames / 4 s   (~15 fps)
#   inside a herdr pane       10-11 changed frames / 4 s (~2.5 fps)   <- 0.9.0 AND 0.9.1 alike
# The browser emits 58-82 a=T frames/s in both cases (strace), so the loss is herdr's graphics
# consumer, not the page, the easing, the pager, aerc, or scrolling.
#
# The fixture flashes the whole viewport every rAF, which removes the confound that wasted an
# evening: ffprobe scores frame-to-frame DIFFERENCE, so a sparse page under 5px eased steps reads
# as a slow pipeline. Full-screen change on both sides or the comparison is not a comparison.
#
# Target is ghostty's own number, not a wish: 45 frames in 4 s (~11 fps) is three quarters of it.
# Exit 0 met, 1 unmet, 3 could-not-run.
set -uo pipefail

MIN=${MIN_PAINT_FRAMES:-45}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts

# The compositor environment: a Stop hook and an ssh shell both have none, and without it hyprctl
# returns non-JSON and desktop.sh reports a window that never appeared.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  __g=$(pgrep -f "ghostty.*herdr" 2>/dev/null | head -1)
  [ -n "${__g:-}" ] && eval "$(tr '\0' '\n' < /proc/"$__g"/environ \
    | grep -E "^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|DISPLAY|DBUS_SESSION_BUS_ADDRESS)=" \
    | sed "s/^/export /")"
fi
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { echo "no compositor environment to borrow" >&2; exit 3; }
[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }
for t in hyprctl jq gpu-screen-recorder ffprobe python3; do
  command -v "$t" >/dev/null || { echo "missing tool $t" >&2; exit 3; }
done

WORK=$(mktemp -d); TAB=""
cleanup() {
  [ -n "${TAB:-}" ] && h tab close "$TAB" >/dev/null 2>&1
  timeout 20 "$TB" shutdown >/dev/null 2>&1
  rm -rf "$WORK"
}
. "$SCRIPTS/desktop.sh"
trap cleanup EXIT

python3 - "$WORK/flash.html" <<'PY'
import sys
open(sys.argv[1], "w").write("""<html><body style="margin:0">
<div id="b" style="width:100vw;height:100vh"></div>
<script>let n=0;const b=document.getElementById('b');
function f(){n++;b.style.background=(n%2)?'#ffffff':'#000000';requestAnimationFrame(f);}
requestAnimationFrame(f);</script></body></html>""")
PY

timeout 20 "$TB" shutdown >/dev/null 2>&1        # own the daemon: transport is fixed at its start
test_session_ensure >/dev/null 2>&1 || { echo "no test session" >&2; exit 3; }

# A FRESH, FOCUSED tab. Reusing a pane types into whatever already runs there, and a --no-focus tab
# is never displayed, so the recorder counts 0 -- indistinguishable from catastrophically slow.
TAB=$(h tab create --workspace "$TEST_WS" --cwd "$HOME" --label paint-gate 2>/dev/null | jq -r '.result.tab.tab_id // empty')
[ -n "${TAB:-}" ] || { echo "could not create a tab" >&2; exit 3; }
h tab focus "$TAB" >/dev/null 2>&1
PANE=$(h pane list 2>/dev/null | jq -r --arg t "$TAB" '[.result.panes[] | select(.tab_id==$t) | .pane_id][0] // empty')
[ -n "${PANE:-}" ] || { echo "no pane in the new tab" >&2; exit 3; }

printf '#!/usr/bin/env bash\nexec "%s" open file://%s\n' "$TB" "$WORK/flash.html" > "$WORK/run.sh"
chmod +x "$WORK/run.sh"
h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(pgrep -f '[t]erminal-browser/app' | wc -l)" -gt 0 ] && break
  sleep 1
done
[ "$(pgrep -f '[t]erminal-browser/app' | wc -l)" -gt 0 ] || { echo "the browser never started" >&2; exit 3; }
sleep 8                                          # frames take several seconds to start arriving

MP4="$WORK/paint.mp4"
gpu-screen-recorder -w region -region "$TEST_GEO" -f 60 -a "" -o "$MP4" > "$WORK/gsr.log" 2>&1 & G=$!
sleep 4; kill -INT "$G" 2>/dev/null; wait "$G" 2>/dev/null
[ -s "$MP4" ] || { echo "the recorder wrote no video; see $WORK/gsr.log" >&2; exit 3; }

F=$(ffprobe -v error -f lavfi -i "movie=$MP4,select=gt(scene\,0.0005)" -show_entries frame=pts_time -of csv=p=0 2>/dev/null | wc -l)
echo "herdr painted $F changed frames in ~4 s (~$((F / 4)) fps); target $MIN (~$((MIN / 4)) fps, ghostty alone manages 59)"
[ "$F" -ge "$MIN" ] && exit 0
exit 1
