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
# THIS GATE IS KNOWN TO DISCRIMINATE, which is not something its earlier verdicts established.
# Measured 2026-09-22 on ONE source build, changing only whether restore_direct_graphics does its
# work (an env-gated early return, reverted after the run):
#   restore path present -> exit 0, "direct graphics restored" logged at T+54s
#   restore path removed -> exit 1, suspension logged and no restore in 100s
# Same trigger, same fixture, same binary otherwise. Before this the gate could only ever exit 3
# (see the logs() note below), so every prior MET/UNMET attributed to it was void.
#
# HERDR_LATCH_BIN picks the herdr under test (default: the installed one).
# Exit 0 it recovered, 1 it never did (the latch), 3 could-not-run.
set -uo pipefail

# AN AUDIT TRAIL, because the only caller that matters reports an exit code and nothing else.
# The Stop hook runs this gate in its own environment and reported exit 3 while nine consecutive
# interactive runs exited 0 -- so the discrepancy is the environment, and a bare code cannot say
# which exit-3 branch was taken. Everything this script prints is teed here. Tempdir, not the
# project: session-scoped and written on every run.
AUDIT=${LATCH_AUDIT:-${TMPDIR:-/tmp}/aerc-latch-gate.log}
if : >> "$AUDIT" 2>/dev/null; then
  printf '\n=== %s pid=%s tty=%s term=%s hypr=%s ===\n' \
    "$(date -Is)" "$$" "$([ -t 1 ] && echo yes || echo no)" "${TERM:-unset}" \
    "${HYPRLAND_INSTANCE_SIGNATURE:+set}" >> "$AUDIT"
  exec > >(tee -a "$AUDIT") 2>&1
fi

HERDR_BIN=${HERDR_LATCH_BIN:-/home/eh/.local/share/mise/installs/herdr/latest/herdr}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
GH="$HOME/.nix-profile/bin/ghostty"
SESSION=${LATCH_SESSION:-latchgate}
# One stall must outlast the deadline that is actually armed. That is DIRECT_DELIVERY_TIMEOUT (5s)
# from the server's send, or DIRECT_RESPONSE_TIMEOUT (3s) once the client has begun writing, both
# capped by DIRECT_OUTER_TIMEOUT (9s). 8s clears the two that fire in practice with margin, and a
# SHORTER stall is safer here rather than weaker: the freeze is repeated below until the suspension
# is observed, and every second frozen is a second in which the client may lose its connection and
# reconnect -- which restores the transport and voids the run.
STALL_SECONDS=${LATCH_STALL_SECONDS:-8}
# A STALL ONLY COSTS SOMETHING IF A TRANSFER IS IN FLIGHT WHEN IT LANDS, and nothing observable
# from outside says when that is. The gate exists only between the server's send and the client's
# completion, so a client stopped between frames has no armed deadline to blow -- and, being
# stopped, it will not ask for the next one either. Measured 2026-09-22 with the correct process
# frozen and the transport confirmed direct-kitty immediately before: one run in three still logged
# no suspension. So do not take a single shot at it. Stall, let the client run long enough to pull
# another transfer, and stall again, stopping the moment the server reports the suspension.
STALL_CYCLES=${LATCH_STALL_CYCLES:-4}
RUN_WINDOW=${LATCH_RUN_WINDOW:-1.5}
# DIRECT_GRAPHICS_COOLDOWN is 60s, so a fixed binary needs a minute plus slack before it restores.
RECOVER_SECONDS=${LATCH_RECOVER_SECONDS:-100}
# A RECONNECT ALSO RESTORES THE TRANSPORT, and counting it as recovery inverts this gate: the
# handshake is the other place direct_graphics is set true, and reconnecting is exactly the manual
# workaround users perform. Measured 2026-09-22 on the INSTALLED 0.9.1, which has no restore path
# at all: the transport came back at T+6s, far inside the 60s cooldown -- that was a reconnect
# reading as a pass. Only the cooldown can legitimately restore it, so a recovery sooner than this
# is not the fix working and the run measured nothing.
MIN_RECOVER_SECONDS=${LATCH_MIN_RECOVER_SECONDS:-30}
# A SINGLE ABSENT READING IS NOT AN EXPIRY. pane.graphics.info answers ABSENT while the client is
# still catching up from the stall, so a blip reads as a loss and the recovery two seconds later
# reads as the fix working -- on a binary that has no restore path at all. Measured 2026-09-22: a
# 5s stall gave "lost, back at T+2s" three times out of three on the installed 0.9.1. Require the
# loss to HOLD before asking whether it recovers.
LOSS_CONFIRM_SECONDS=${LATCH_LOSS_CONFIRM_SECONDS:-10}

# THE RECONNECT DETECTOR, and it is evidence rather than a heuristic. The handshake is the other
# place direct_graphics is set true, so a client that reconnects restores the transport and reads as
# a pass. Timing alone could not separate the two: the freeze needed to blow DIRECT_OUTER_TIMEOUT
# (9s) is also long enough to cost the client its connection, so the reconnect lands BEFORE the 60s
# cooldown could. herdr logs every one -- "client connected client_id=N" -- so count them instead.
# THE GATE'S OWN SESSION LOG, and only it. `herdr --session <name>` puts data_dir at
# config_dir/sessions/<name> (session.rs data_dir_for), so the server started by this gate logs to
# sessions/$SESSION/herdr-server.log. This used to read the two GLOBAL logs, which the gate's server
# never writes a line to: suspends() was therefore always 0 and the run could only ever exit 3,
# whatever the trigger did. Reading the global log is not merely useless either -- it is the user's
# live server, and its unrelated "client connected" lines inflate connects() and trip the reconnect
# guard on traffic that has nothing to do with this measurement.
logs() { cat "$HOME/.config/herdr/sessions/$SESSION/herdr-server.log" \
             "$HOME/.config/herdr-dev/sessions/$SESSION/herdr-server.log" 2>/dev/null; }
connects()  { logs | grep -c "client connected"; }
# THE SERVER'S OWN ACCOUNT OF THE EXPIRY. Watching file_frame_transport cannot establish one:
# pane.graphics.info reports the CLIENT's state, so it answers ABSENT both for a real suspension
# and for a client still catching up from the stall, and a 1s blip read as a loss three separate
# times. These two lines were added to herdr (992172b9) precisely so the gate can stop guessing.
suspends() { logs | grep -c "direct graphics suspended"; }
restores() { logs | grep -c "direct graphics restored"; }

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
  # REAP BY THE PAGE PATH, not by XDG_RUNTIME_DIR=$PRIV, which matches nothing (see the note at the
  # stall). That inert match is why this gate leaked electron processes on every run. $WORK is a
  # mktemp -d path and appears in our CLI invocation's command line and nowhere else.
  for c in /proc/[0-9]*/cmdline; do
    grep -qa -- "$WORK" "$c" 2>/dev/null || continue
    __p=${c#/proc/}; __p=${__p%/cmdline}
    [ "$__p" = "$$" ] && continue
    kill "$__p" 2>/dev/null
  done
  env HERDR_SOCKET_PATH="$SOCK" timeout 20 "$HERDR_BIN" server stop >/dev/null 2>&1
  for z in $(ps -eo pid=,args= | awk '/[d]ev\.latchgate/ && !/awk/ {print $1}'); do kill -CONT "$z" 2>/dev/null; kill "$z" 2>/dev/null; done
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
  # A TRANSFER MUST BE IN FLIGHT WHEN WE STALL, or the stall costs nothing and the run is void.
  # This is what made the trigger 50/50: `pane run` returns at once but electron takes seconds to
  # boot, so a 12s stall often covered a browser that had not painted yet -- the ABSENT reading was
  # just the frozen client, and the "recovery" was the first paint finally arriving. A static page
  # has the same problem from the other end: once it has painted, nothing transfers. So give the
  # fixture a permanent repaint. The email's own content is untouched; this only guarantees the
  # deadline is armed whenever we choose to stall.
  cat >> "$WORK/page.html" <<'ANIM'
<div style="position:fixed;top:0;left:0;width:64px;height:64px;background:#111;
            animation:latchspin 1s linear infinite"></div>
<style>@keyframes latchspin{from{transform:rotate(0)}to{transform:rotate(360deg)}}</style>
ANIM
else
  echo "no fixture at $PAGE; falling back to a synthetic page, which transfers too fast to be faithful" >&2
  python3 - "$WORK/page.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">paint survival line {i}</p>' for i in range(600))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY
fi

UNSET=$(for v in $(env | grep -oE '^(HERDR|SSH|TMUX|STY)[A-Z_]*' | sort -u); do printf -- "-u %s " "$v"; done)
# READY MEANS ANSWERING, NOT PRESENT. This used to return the moment a socket FILE existed, which
# is true of a socket left by the previous run's server while it is still shutting down, and true
# of a stale file no one holds. The run then went on to `pane list`, got nothing, and exited 3 with
# "no pane in the test session" -- a could-not-run that looks like a flaky gate. Back-to-back runs
# are the normal case here (the Stop hook fires one right after an interactive one), so the race is
# the common path rather than an edge.
session_answers() {
  for __s in "$SOCK_REL" "$SOCK_DEV"; do
    [ -S "$__s" ] || continue
    env HERDR_SOCKET_PATH="$__s" timeout 10 "$HERDR_BIN" pane list 2>/dev/null \
      | grep -v "^mise " \
      | python3 -c "import sys,json;sys.exit(0 if json.load(sys.stdin)['result']['panes'] else 1)" 2>/dev/null \
      && { SOCK="$__s"; return 0; }
  done
  return 1
}
start_session() {
  # Retire any server still holding this session's socket before claiming the name.
  for __s in "$SOCK_REL" "$SOCK_DEV"; do
    [ -S "$__s" ] && env HERDR_SOCKET_PATH="$__s" timeout 20 "$HERDR_BIN" server stop >/dev/null 2>&1
  done
  for _ in $(seq 1 15); do
    [ -S "$SOCK_REL" ] || [ -S "$SOCK_DEV" ] || break
    sleep 1
  done
  rm -rf "$HOME/.config/herdr/sessions/$SESSION" "$HOME/.config/herdr-dev/sessions/$SESSION" 2>/dev/null
  # shellcheck disable=SC2086
  setsid env $UNSET "$GH" --gtk-single-instance=false --class=dev.latchgate \
    -e bash -c "env $UNSET $HERDR_BIN --session $SESSION" > "$WORK/ghostty.log" 2>&1 &
  for _ in $(seq 1 45); do
    session_answers && return 0
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
#
# STALL THE CLIENT, NOT THE WINDOW. This pattern used to be /[d]ev\.latchgate/, which matches the
# GHOSTTY process and nothing else: the herdr client execs over `env`, so its command line is
# "<herdr> --session latchgate" and carries no class string. Two reasons that trigger could not
# work, and together they are the 50/50 the header describes:
#   1. The gate is owed a response by the CLIENT. Freezing its terminal emulator leaves the client
#      running, reading the socket and answering on time.
#   2. Under the FILE transport the client writes ~135 bytes -- a kitty escape naming a path -- so
#      a stopped terminal's pty never fills and the client never blocks on it. The payload the
#      deadline is about never crosses the pty at all.
# A stopped client cannot read the transmission off the socket, so DIRECT_DELIVERY_TIMEOUT expires
# with certainty while a transfer is in flight, which the animated fixture guarantees.
window_pids() { ps -eo pid=,args= | awk '/[d]ev\.latchgate/ && !/awk/ {print $1}'; }
client_pids() {
  ps -eo pid=,args= | awk -v s="--session $SESSION" \
    'index($0, s) && !/ghostty/ && !/awk/ && !/check-latch-recovers/ {print $1}'
}
PIDS=$(client_pids)
[ -n "${PIDS:-}" ] || { echo "could not find the client process to stall" >&2; exit 3; }
# Say WHAT is being stalled. When this gate reports "no suspension" the first question is always
# whether it froze the right process, and without this line that cannot be answered after the fact.
for p in $PIDS; do echo "  will stall pid $p: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-90)"; done

# ORDER MATTERS. The deadline is armed only while a transfer is IN FLIGHT, so stalling a client
# that has nothing pending costs nothing -- the first attempt stopped it after a static page had
# finished painting and the transport never dropped. Stop the client FIRST, then start the browser:
# its opening transfer is then in flight against a client that cannot answer, which is exactly the
# documented cause (a busy host, or electron booting cold).
if [ "$STALL_SECONDS" -gt 0 ]; then
  # Start the browser FIRST and let it reach a steady repaint, so the stall lands on a transfer
  # that is actually in flight. Stalling before electron has booted is what voided half the runs.
  h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1
  for _ in $(seq 1 "${LATCH_PAINT_WAIT:-25}"); do
    [ "$(transport "$PANE")" = "direct-kitty" ] && break
    sleep 1
  done
  sleep "${LATCH_SETTLE:-6}"
  # NO READINESS PROBE KEYED ON $PRIV. Measured 2026-09-22: XDG_RUNTIME_DIR=$PRIV does NOT isolate
  # terminal-browser -- its socket still lands in /run/user/1000/terminal-browser-<hash>/ and its
  # electron processes carry no XDG_RUNTIME_DIR at all. Any check matching on that variable matches
  # nothing, which is also why cleanup() below reaps by the page path instead. A CPU-based paint
  # probe was written against $PRIV, could never match, and was removed rather than loosened.
  # pane.graphics.info carries no frame counter either, so the server offers no paint signal.
  # What remains is the duty cycle below, which retries instead of asserting readiness.
  echo "  transport immediately before the stall: $(transport "$PANE")"
  CONNECTS_BEFORE=$(connects); SUSPENDS_BEFORE=$(suspends); RESTORES_BEFORE=$(restores)
  CYCLES_USED=0
  for _c in $(seq 1 "$STALL_CYCLES"); do
    CYCLES_USED=$_c
    for p in $PIDS; do kill -STOP "$p" 2>/dev/null; done
    sleep "$STALL_SECONDS"
    for p in $PIDS; do kill -CONT "$p" 2>/dev/null; done
    [ "$(suspends)" -gt "${SUSPENDS_BEFORE:-0}" ] && break
    sleep "$RUN_WINDOW"
  done
  echo "stalled the client ${STALL_SECONDS}s x${CYCLES_USED} across live transfers, then resumed it"
else
  # LATCH_STALL_SECONDS=0: no stall at all. The question is whether the real fixture's own first
  # transfer misses the deadline, which is what a user actually hits.
  CONNECTS_BEFORE=$(connects); SUSPENDS_BEFORE=$(suspends); RESTORES_BEFORE=$(restores)
  h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1
  echo "no stall; letting the fixture's own first transfer run against the deadline"
fi

# Did the stall actually cost us the transport? If not, this run measured nothing -- say so rather
# than reporting a recovery that was never a loss.
# DID THE SERVER ACTUALLY SUSPEND? Only its own log can say. No suspend line means the stall never
# blew a deadline -- the run measured nothing, and no amount of ABSENT readings changes that.
for i in $(seq 1 30); do
  [ "$(suspends)" -gt "${SUSPENDS_BEFORE:-0}" ] && break
  sleep 1
done
if [ "$(suspends)" -le "${SUSPENDS_BEFORE:-0}" ]; then
  echo "the server logged no suspension, so the stall blew no deadline -- nothing to recover from." >&2
  echo "  (If this herdr predates the suspend/restore logging, it cannot be measured this way.)" >&2
  exit 3
fi
echo "lost: the server logged a direct-graphics suspension"

for i in $(seq 1 "$RECOVER_SECONDS"); do
  if [ "$(restores)" -gt "${RESTORES_BEFORE:-0}" ]; then
    echo "MET: the server logged a direct-graphics restore at T+${i}s -- a suspension, not a latch"
    exit 0
  fi
  NOW=$(connects)
  if [ "${NOW:-0}" -gt "${CONNECTS_BEFORE:-0}" ] && [ "$(transport "$PANE")" = "direct-kitty" ]; then
    echo "the transport came back at T+${i}s, but via $((NOW - CONNECTS_BEFORE)) new client" >&2
    echo "  connection(s) and with no restore logged -- a RECONNECT, which is the manual workaround" >&2
    echo "  a user performs, not the server giving the path back. Measured nothing." >&2
    exit 3
  fi
  sleep 1
done

echo "UNMET: the server suspended direct graphics and never logged a restore in ${RECOVER_SECONDS}s"
echo "  -- it is a ONE-WAY LATCH. expire_direct_graphics clears client.direct_graphics and only the"
echo "  handshake sets it true, so this connection is on the pty fallback for good: every frame from"
echo "  here is a full surface down the pty until the client reconnects."
exit 1
