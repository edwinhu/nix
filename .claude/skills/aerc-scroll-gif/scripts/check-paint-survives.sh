#!/usr/bin/env bash
# GATE: rendering a page must not destroy the direct-kitty transport.
#
# Measured 2026-09-22: a restarted client holds direct-kitty for 93 minutes with nothing painting,
# and loses it within 3 SECONDS of a browser starting -- 3s being DIRECT_RESPONSE_TIMEOUT. The
# expiry path (src/server/headless/pane_graphics.rs:402) clears client.direct_graphics, and only
# the handshake ever sets it back, so a client restart buys about one page load at full speed and
# every frame after that goes down the pty: 24 full-surface transmits and 216 MB per 2400px scroll
# against zero on the direct path.
#
# This is the objective the other gates do not state. check-direct-kitty.sh passes while this
# fails, because it reads the transport once against a session whose browser has only just started.
#
# HERDR_PAINT_BIN picks the herdr under test (default: the installed one).
# Exit 0 the transport survived the paint, 1 it was lost, 3 could-not-run.
set -uo pipefail

HERDR_BIN=${HERDR_PAINT_BIN:-/home/eh/.local/share/mise/installs/herdr/latest/herdr}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
GH="$HOME/.nix-profile/bin/ghostty"
SESSION=${PAINT_SESSION:-paintgate}
HOLD_SECONDS=${PAINT_HOLD_SECONDS:-30}

[ -x "$HERDR_BIN" ] || { echo "no herdr at $HERDR_BIN" >&2; exit 3; }
[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }

if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  for __g in $(pgrep -f "[g]hostty.*herdr" 2>/dev/null); do
    grep -qz "HYPRLAND_INSTANCE_SIGNATURE" /proc/"$__g"/environ 2>/dev/null || continue
    eval "$(tr '\0' '\n' < /proc/"$__g"/environ \
      | grep -E "^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|DISPLAY|XDG_SESSION_TYPE|GDK_BACKEND)=" \
      | sed 's/^/export /')"
    break
  done
fi
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { echo "no compositor environment to borrow" >&2; exit 3; }

WORK=$(mktemp -d)
PRIV="$WORK/xdg"; mkdir -p "$PRIV"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  for e in "$XDG_RUNTIME_DIR"/*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in terminal-browser*) continue ;; esac
    ln -sfn "$e" "$PRIV/${e##*/}" 2>/dev/null
  done
fi
SOCK_REL="$HOME/.config/herdr/sessions/$SESSION/herdr.sock"
SOCK_DEV="$HOME/.config/herdr-dev/sessions/$SESSION/herdr.sock"
SOCK="$SOCK_REL"
cleanup() {
  for c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
    __p=${c#/proc/}; __p=${__p%/environ}
    grep -qa "electron" /proc/"$__p"/cmdline 2>/dev/null && kill "$__p" 2>/dev/null
  done
  env HERDR_SOCKET_PATH="$SOCK" timeout 20 "$HERDR_BIN" server stop >/dev/null 2>&1
  for z in $(ps -eo pid=,args= | awk '/dev\.paintgate/ && !/awk/ {print $1}'); do kill "$z" 2>/dev/null; done
  for z in $(ps -eo pid=,args= | awk '/dev\.paintgate-ssh/ && !/awk/ {print $1}'); do kill "$z" 2>/dev/null; done
  rm -rf "$WORK" "$HOME/.config/herdr/sessions/$SESSION" "$HOME/.config/herdr-dev/sessions/$SESSION" 2>/dev/null
}
trap cleanup EXIT

python3 - "$WORK/page.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">paint survival line {i}</p>' for i in range(600))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY

UNSET=$(for v in $(env | grep -oE '^(HERDR|SSH|TMUX|STY)[A-Z_]*' | sort -u); do printf -- "-u %s " "$v"; done)
start_session() {
  rm -rf "$HOME/.config/herdr/sessions/$SESSION" "$HOME/.config/herdr-dev/sessions/$SESSION" 2>/dev/null
  # shellcheck disable=SC2086
  setsid env $UNSET "$GH" --gtk-single-instance=false --class=dev.paintgate \
    -e bash -c "env $UNSET $HERDR_BIN --session $SESSION" > "$WORK/ghostty.log" 2>&1 &
  for _ in $(seq 1 45); do
    [ -S "$SOCK_REL" ] && { SOCK="$SOCK_REL"; return 0; }
    [ -S "$SOCK_DEV" ] && { SOCK="$SOCK_DEV"; return 0; }
    sleep 1
  done
  return 1
}
start_session || { echo "the test window did not come up; retrying once (ghostty SIGSEGVs here)" >&2
                   start_session || { echo "no test session after two attempts" >&2; exit 3; }; }
sleep 4

h() { env HERDR_SOCKET_PATH="$SOCK" timeout 25 "$HERDR_BIN" "$@" 2>/dev/null | grep -v "^mise "; }
transport() {
  python3 - "$SOCK" "$1" <<'PY' 2>/dev/null
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(6); s.connect(sys.argv[1])
    s.sendall((json.dumps({"id":"i","method":"pane.graphics.info","params":{"pane_id":sys.argv[2]}})+"\n").encode())
    b = b""
    while b"\n" not in b:
        d = s.recv(65536)
        if not d: break
        b += d
    print(json.loads(b.decode().split("\n")[0])["result"].get("file_frame_transport") or "ABSENT")
except Exception:
    print("ERR")
PY
}

SHELL_PANE=$(h pane list | python3 -c "import sys,json; p=json.load(sys.stdin)['result']['panes']; print(p[0]['pane_id'] if p else '')" 2>/dev/null)
[ -n "${SHELL_PANE:-}" ] || { echo "no pane in the test session" >&2; exit 3; }
PANE=$(h pane split --pane "$SHELL_PANE" --direction down --ratio 0.6 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])" 2>/dev/null)
[ -n "${PANE:-}" ] || { echo "could not split a pane" >&2; exit 3; }

# NO REMOTE CLIENT IS ATTACHED HERE, and that is a correction rather than a simplification.
# An earlier version attached an ssh-marked client to reproduce the live session, and it did strip
# direct-kitty -- but that is DELIBERATE upstream behaviour, pinned by a passing test
# (direct_graphics_availability_follows_foreground_client_with_background_clients): an incapable
# FOREGROUND client means no direct graphics even when a capable background client exists. The
# reason is sound -- direct frames are written for one client to read, so serving them to a client
# that is not the one displaying paints nothing for the person looking. A patch making the server
# fall back to any capable client builds and then fails that test; it was written, run, and
# reverted rather than loosened.
#
# So this gate asserts only the part that is a defect: rendering must not DESTROY the transport.
# Caveat worth keeping in view -- a throwaway session passes while the user's live session fails,
# and the difference is a remote bridge attached there. That failure is the 3s expiry latch
# (pane_graphics.rs:402), not the foreground rule, and this gate does not reproduce it.

BEFORE=$(transport "$PANE")
# ERR IS NOT A VERDICT. transport() prints ERR when the socket query itself fails -- no session, a
# ghostty that segfaulted on both attempts, a timeout -- which says nothing about the transport.
# Observed 2026-09-22: a run whose window never came up read ERR and was reported as
# "UNMET: a remote client attached ... This is herdr #3138", blaming the product for a measurement
# that never happened. A failed query is could-not-run, and could-not-run is exit 3.
if [ "$BEFORE" = "ERR" ] || [ -z "${BEFORE:-}" ]; then
  echo "the graphics query failed (read '${BEFORE:-empty}'), so nothing was measured -- not a verdict" >&2
  exit 3
fi
if [ "$BEFORE" != "direct-kitty" ]; then
  if [ "${PAINT_WITH_REMOTE:-1}" = "1" ]; then
    # This is the defect, not a broken measurement: a REMOTE client attaching removes direct-kitty
    # from panes that a capable LOCAL client is serving. Upstream herdr #3138, still open. The
    # local client is unchanged and still capable; the server simply stops choosing it.
    echo "UNMET: a remote client attached and the transport went to $BEFORE without anything painting."
    echo "  The local client is still attached and still capable. herdr picks the direct-graphics"
    echo "  client from the FOREGROUND client (src/server/headless.rs direct_graphics_client), so"
    echo "  one remote attach downgrades every pane in the session. This is herdr #3138."
    exit 1
  fi
  echo "the transport was already $BEFORE before anything painted; cannot measure the paint" >&2
  exit 3
fi
echo "before any paint: $BEFORE"

printf '#!/usr/bin/env bash\nexport XDG_RUNTIME_DIR=%s\nexec %s open file://%s\n' "$PRIV" "$TB" "$WORK/page.html" > "$WORK/run.sh"
chmod +x "$WORK/run.sh"
h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

# file_frame_transport is the CLIENT's state: it answers ABSENT both when the server has genuinely
# suspended direct graphics and when the client is simply not answering yet. So a reading alone is
# not a loss. Where the herdr under test logs the suspension (992172b9), the server's own account
# decides; where it does not, an ABSENT reading is reported as unattributed rather than explained.
# THE GATE'S OWN SESSION LOG. `herdr --session <name>` puts data_dir at config_dir/sessions/<name>
# (session.rs data_dir_for), so the server this gate starts writes nowhere near the two GLOBAL
# paths this used to read: the count was always 0 and the UNMET branch below could only ever take
# its "no suspension was logged" arm, whatever the server actually did. The same defect was found
# and fixed in check-latch-recovers.sh, where it made every verdict impossible.
plogs() { cat "$HOME/.config/herdr/sessions/$SESSION/herdr-server.log" \
              "$HOME/.config/herdr-dev/sessions/$SESSION/herdr-server.log" 2>/dev/null; }
SUSPENDS_BEFORE=$(plogs | grep -c "direct graphics suspended")

LOST=""
for i in $(seq 1 "$HOLD_SECONDS"); do
  T=$(transport "$PANE")
  if [ "$T" != "direct-kitty" ]; then LOST="$T at T+${i}s"; break; fi
  sleep 1
done

if [ -n "$LOST" ]; then
  SUSPENDS_AFTER=$(plogs | grep -c "direct graphics suspended")
  echo "UNMET: the transport read $LOST while painting"
  if [ "${SUSPENDS_AFTER:-0}" -gt "${SUSPENDS_BEFORE:-0}" ]; then
    echo "  The server logged a direct-graphics suspension, so this is the expiry path in"
    echo "  server/headless/pane_graphics.rs: a transfer missed its deadline."
  else
    echo "  The server logged NO suspension, so do NOT attribute this to the expiry latch. Measured"
    echo "  2026-09-22: the latch was never once observed firing, and every ABSENT reading taken"
    echo "  from this field was consistent with a client that had not answered yet. The other way"
    echo "  the transport goes absent is the FOREGROUND-CLIENT rule -- a remote or ssh-marked client"
    echo "  being foreground disables direct graphics by design -- which is what the live session"
    echo "  turned out to be. Establish which before building on this verdict."
  fi
  exit 1
fi
echo "MET: direct-kitty survived ${HOLD_SECONDS}s of painting"
exit 0
