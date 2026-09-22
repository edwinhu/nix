#!/usr/bin/env bash
# GATE: losing the direct-kitty transport must be TEMPORARY, not permanent.
#
# expire_direct_graphics clears client.direct_graphics, and the handshake is the ONLY place that
# ever sets it true, so the field is a one-way latch: one transfer that misses its deadline
# downgrades that client to the pty fallback for the entire life of the connection, with no path
# back. The deadlines are 3, 5 and 9 seconds, so an ordinary hiccup qualifies -- a 15 MB surface
# while the host is busy, a suspend, a stalled compositor, or simply electron booting cold.
#
# WHY THIS DOES NOT WAIT FOR THE RACE. check-paint-survives.sh reproduces the loss only when the
# first transfer happens to be slow, which on a warm machine it is not: measured 2026-09-22 it read
# UNMET once on a cold page cache and MET four times in a row afterwards, on an UNCHANGED binary.
# A gate whose verdict depends on page-cache warmth reports MET on a machine where users still hit
# the bug, and an A/B run across it proves nothing. So force the loss instead of hoping for it:
# SIGSTOP the client past DIRECT_OUTER_TIMEOUT (9s) -- "the host is busy", which is the documented
# cause -- then SIGCONT and ask the only question that separates a hiccup from a latch:
#
#   does the transport EVER come back?
#
# Recovery is capped by what the handshake negotiated, so a client that never had the capability
# never gains one; this gate establishes direct-kitty first and refuses to run otherwise.
#
# HERDR_LATCH_BIN picks the herdr under test (default: the installed one).
# Exit 0 it recovered, 1 it never did (the latch), 3 could-not-run.
set -uo pipefail

HERDR_BIN=${HERDR_LATCH_BIN:-/home/eh/.local/share/mise/installs/herdr/latest/herdr}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
GH="$HOME/.nix-profile/bin/ghostty"
SESSION=${LATCH_SESSION:-latchgate}
STALL_SECONDS=${LATCH_STALL_SECONDS:-12}      # > DIRECT_OUTER_TIMEOUT (9s)
# DIRECT_GRAPHICS_COOLDOWN is 60s, so a fixed binary needs a minute plus slack before it restores.
RECOVER_SECONDS=${LATCH_RECOVER_SECONDS:-100}
# A RECONNECT ALSO RESTORES THE TRANSPORT, and counting it as recovery inverts this gate: the
# handshake is the other place direct_graphics is set true, and reconnecting is exactly the manual
# workaround users perform. Measured 2026-09-22 on the INSTALLED 0.9.1, which has no restore path
# at all: the transport came back at T+6s, far inside the 60s cooldown -- that was a reconnect
# reading as a pass. Only the cooldown can legitimately restore it, so a recovery sooner than this
# is not the fix working and the run measured nothing.
MIN_RECOVER_SECONDS=${LATCH_MIN_RECOVER_SECONDS:-30}

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

# THE FIXTURE IS THE REAL EMAIL. The rest of this suite drives aerc with --query from:arcteryx,
# and fixture weight is what decides whether the FIRST transfer blows a 3s deadline: the Arc'teryx
# mail is 88 KB over 62 images where the synthetic page this gate used to build was a few hundred
# lines of text. Regenerate with:
#   notmuch show --format=raw 'from:arcteryx' | (extract the text/html part)
PAGE=${LATCH_PAGE:-/home/eh/nix/.craft/fixtures/arcteryx.html}
if [ -r "$PAGE" ]; then
  cp "$PAGE" "$WORK/page.html"
else
  echo "no fixture at $PAGE; falling back to a synthetic page, which transfers too fast to be faithful" >&2
  python3 - "$WORK/page.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">paint survival line {i}</p>' for i in range(600))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY
fi

UNSET=$(for v in $(env | grep -oE '^(HERDR|SSH|TMUX|STY)[A-Z_]*' | sort -u); do printf -- "-u %s " "$v"; done)
start_session() {
  rm -rf "$HOME/.config/herdr/sessions/$SESSION" "$HOME/.config/herdr-dev/sessions/$SESSION" 2>/dev/null
  # shellcheck disable=SC2086
  setsid env $UNSET "$GH" --gtk-single-instance=false --class=dev.latchgate \
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

BEFORE=$(transport "$PANE")
[ "$BEFORE" = "direct-kitty" ] || {
  echo "the transport was $BEFORE before anything ran; this gate needs direct-kitty to lose" >&2
  exit 3
}
echo "before: $BEFORE"

printf '#!/usr/bin/env bash\nexport XDG_RUNTIME_DIR=%s\nexec %s open file://%s\n' "$PRIV" "$TB" "$WORK/page.html" > "$WORK/run.sh"
chmod +x "$WORK/run.sh"
# Explicit PIDs, never `pkill -f`: -f matches this script's own command line and has killed the
# shell running it (exit 144). The [d] bracket keeps the awk out of its own match.
client_pids() { ps -eo pid=,args= | awk '/[d]ev\.latchgate/ && !/awk/ {print $1}'; }
PIDS=$(client_pids)
[ -n "${PIDS:-}" ] || { echo "could not find the client process to stall" >&2; exit 3; }

# ORDER MATTERS. The deadline is armed only while a transfer is IN FLIGHT, so stalling a client
# that has nothing pending costs nothing -- the first attempt stopped it after a static page had
# finished painting and the transport never dropped. Stop the client FIRST, then start the browser:
# its opening transfer is then in flight against a client that cannot answer, which is exactly the
# documented cause (a busy host, or electron booting cold).
if [ "$STALL_SECONDS" -gt 0 ]; then
  for p in $PIDS; do kill -STOP "$p" 2>/dev/null; done
  h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1
  sleep "$STALL_SECONDS"
  for p in $PIDS; do kill -CONT "$p" 2>/dev/null; done
  echo "stalled the client ${STALL_SECONDS}s across the browser's first transfer, then resumed it"
else
  # LATCH_STALL_SECONDS=0: no stall at all. The question is whether the real fixture's own first
  # transfer misses the deadline, which is what a user actually hits.
  h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1
  echo "no stall; letting the fixture's own first transfer run against the deadline"
fi

# Did the stall actually cost us the transport? If not, this run measured nothing -- say so rather
# than reporting a recovery that was never a loss.
LOST=""
for i in $(seq 1 15); do
  T=$(transport "$PANE")
  if [ "$T" != "direct-kitty" ]; then LOST="$T"; break; fi
  sleep 1
done
[ -n "$LOST" ] || {
  echo "the stall did not cost the transport (still direct-kitty); nothing to recover from" >&2
  echo "  raise LATCH_STALL_SECONDS above the outer timeout, or the deadline was not armed" >&2
  exit 3
}
echo "lost: transport went to $LOST after the stall"

for i in $(seq 1 "$RECOVER_SECONDS"); do
  T=$(transport "$PANE")
  if [ "$T" = "direct-kitty" ]; then
    if [ "$i" -lt "$MIN_RECOVER_SECONDS" ]; then
      echo "the transport came back at T+${i}s, inside the ${MIN_RECOVER_SECONDS}s floor -- too fast to be" >&2
      echo "  the ${MIN_RECOVER_SECONDS}s+ cooldown, so a client RECONNECT restored it, not the cooldown." >&2
      echo "  A reconnect is the manual workaround, not the fix; this run measured nothing." >&2
      exit 3
    fi
    echo "MET: the transport came back at T+${i}s after the stall -- the cooldown restored it"
    exit 0
  fi
  sleep 1
done

echo "UNMET: the transport never came back in ${RECOVER_SECONDS}s -- it is a ONE-WAY LATCH"
echo "  expire_direct_graphics (server/headless/pane_graphics.rs) clears client.direct_graphics and"
echo "  only the handshake sets it true, so this connection is on the pty fallback for good: every"
echo "  frame from here is a full surface down the pty until the client reconnects."
exit 1
