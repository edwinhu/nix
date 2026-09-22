#!/usr/bin/env bash
# GATE: terminal-browser actually uses herdr's direct-kitty file transport.
#
# This is the root cause of the o-viewer slowness, and it is upstream-documented twice:
# herdr #3785 (direct-kitty dropped after the first direct file frame, single local ghostty) and
# terminal-browser #97 ("the client falls back to writing VT everywhere, silently, because falling
# back is what working looks like"). Herdr::connect requires pane.graphics.info to answer
# file_frame_transport == "direct-kitty" and returns None otherwise -- then every frame goes down
# the pty as a full-surface kitty escape, herdr re-encodes it as a 21 MB base64 upload, and the
# pane paints at ~2.7 fps against ghostty's own 15-20.
#
# Two conditions, because the advertised field alone proves nothing: the transport must be
# advertised AFTER frames have flowed, and frame FILES must appear in the advertised directory.
# Exit 0 met, 1 unmet, 3 could-not-run.
set -uo pipefail

HERDR_BIN=${HERDR_DIRECT_BIN:-/nix/store/vmgh0yp88y87waiv77ijl5m9yvky0x46-herdr-0.9.1/bin/herdr}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
GH="$HOME/.nix-profile/bin/ghostty"          # nixGL-wrapped; the store binary fails EGL here
SESSION=${DIRECT_KITTY_SESSION:-dkgate}
SOCK="$HOME/.config/herdr/sessions/$SESSION/herdr.sock"

[ -x "$HERDR_BIN" ] || { echo "no herdr binary at $HERDR_BIN" >&2; exit 3; }
[ -x "$TB" ] || { echo "terminal-browser is not installed" >&2; exit 3; }
[ -x "$GH" ] || { echo "no nixGL-wrapped ghostty" >&2; exit 3; }

# The compositor environment: an ssh shell and a Stop hook both have none.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  # [g]hostty, and iterate: a bare "ghostty.*herdr" pattern matches THIS SCRIPT own command line
  # (CLAUDE.md rule 7), and head -1 then borrows from a shell that has no compositor env at all.
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

# A PRIVATE BROWSER DAEMON. The terminal-browser daemon socket is
# $XDG_RUNTIME_DIR/terminal-browser*/daemon.sock, so relocating that one variable gives this gate a
# daemon nobody else can serve -- and, more to the point, one it can own without touching anyone
# else's. This gate runs every half hour; the previous version called `shutdown` and then killed
# every --daemon process on the machine, which closes whatever the user has open in the o viewer.
# A monitor must not damage the thing it monitors. The rest of the real runtime dir is symlinked
# through so the wayland socket and the pane-graphics directory stay reachable.
PRIV="$WORK/xdg"
mkdir -p "$PRIV"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  for e in "$XDG_RUNTIME_DIR"/*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in terminal-browser*) continue ;; esac
    ln -sfn "$e" "$PRIV/${e##*/}" 2>/dev/null
  done
fi
cleanup() {
  # Our own daemon only, found by the private runtime dir it carries -- never `shutdown`, which
  # reaches the user's browser through the shared data dir.
  for c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
    __p=${c#/proc/}; __p=${__p%/environ}
    grep -qa "electron" /proc/"$__p"/cmdline 2>/dev/null && kill "$__p" 2>/dev/null
  done
  env HERDR_SOCKET_PATH="$SOCK" timeout 20 "$HERDR_BIN" server stop >/dev/null 2>&1
  [ -n "${GPID:-}" ] && kill "$GPID" 2>/dev/null
  rm -rf "$WORK" "$HOME/.config/herdr/sessions/$SESSION" 2>/dev/null
}
trap cleanup EXIT

# STRIP HERDR_* AND SSH_*. HERDR_* makes 0.9.1 refuse to start ("nested herdr is disabled"), and
# SSH_CONNECTION/SSH_TTY clear direct_graphics at client handshake
# (herdr src/client/handshake.rs:65-69) -- which is herdr #3138, still open: a remote client
# attaching removes direct-kitty from existing LOCAL panes. Every earlier measurement of this
# problem was launched from an ssh process tree and so could never have used the fast path.
UNSET=$(for v in $(env | grep -oE '^(HERDR|SSH|TMUX|STY)[A-Z_]*' | sort -u); do printf -- "-u %s " "$v"; done)

python3 - "$WORK/page.html" <<'PY'
import sys
rows = "".join(f'<p style="font-size:22px">direct kitty line {i}</p>' for i in range(600))
open(sys.argv[1], "w").write('<html><body style="background:#fff">' + rows + "</body></html>")
PY

rm -rf "$HOME/.config/herdr/sessions/$SESSION" 2>/dev/null
# shellcheck disable=SC2086
# --gtk-single-instance=false: the desktop ghostty runs with single-instance TRUE, so a second
# invocation delegates to that process instead of owning its own window, and the delegating
# instance has been seen to SIGSEGV. A crashed test ghostty kills its herdr client, which removes
# the only direct-graphics-capable client, which makes herdr stop advertising the transport -- an
# UNMET that looks like the bug under test and is not.
setsid env $UNSET "$GH" --gtk-single-instance=false --class=dev.dkgate -e bash -c "env $UNSET $HERDR_BIN --session $SESSION" \
  > "$WORK/ghostty.log" 2>&1 &
GPID=$!
for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || { echo "the test session never opened its socket; see $WORK/ghostty.log" >&2
                    sed -n '$p' "$WORK/ghostty.log" >&2; exit 3; }
sleep 4

h() { env HERDR_SOCKET_PATH="$SOCK" timeout 25 "$HERDR_BIN" "$@" 2>/dev/null | grep -v "^mise "; }
SHELL_PANE=$(h pane list | python3 -c "import sys,json; p=json.load(sys.stdin)['result']['panes']; print(p[0]['pane_id'] if p else '')" 2>/dev/null)
[ -n "${SHELL_PANE:-}" ] || { echo "no pane in the test session" >&2; exit 3; }
# A FRESH SPLIT, not the session shell pane. terminal-browser takes over the tty of the pane it
# runs in and reports "browser did not register within 20s (is the split open?)" when that pane
# already has an interactive shell drawing a prompt.
PANE=$(h pane split --pane "$SHELL_PANE" --direction down --ratio 0.6 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])" 2>/dev/null)
[ -n "${PANE:-}" ] || { echo "could not split a pane in the test session" >&2; exit 3; }

# OWN THE DAEMON. It is shared, long-lived, and reads HERDR_PANE_ID once at startup, so a survivor
# from another pane serves our page against someone else's pane id. `shutdown` is asynchronous and
# does not always win, so wait it out and then kill by explicit pid -- never pkill -f, which matches
# this script own command line and takes the shell down with it.
T0=$(date +%s)
# Own the daemon by ISOLATION, not by killing. Nothing outside this gate is touched.
# NO `terminal-browser shutdown` HERE, deliberately. The daemon socket lives under
# XDG_RUNTIME_DIR, so the private dir above already gives this gate its own daemon -- but the
# shutdown COMMAND resolves its target through the shared XDG_DATA_HOME app dir, so calling it
# killed the user's browser even with the runtime dir relocated. Verified: a decoy daemon died
# across a gate run that contained no kill at all. Nothing global is touched now.
printf '#!/usr/bin/env bash\nexport XDG_RUNTIME_DIR=%s\nexec %s open file://%s\n' "$PRIV" "$TB" "$WORK/page.html" > "$WORK/run.sh"
chmod +x "$WORK/run.sh"
h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

# Wait for the DAEMON, not for any electron: bin/terminal-browser is itself
# `electron cli/dist/main.js`, so a bare app/electron match is satisfied by the CLI and proves
# nothing. The daemon is the process that paints.
# Wait for OUR daemon, identified by the private runtime dir rather than by a global pattern: a
# match on any --daemon would be satisfied by the user's own browser and prove nothing about ours.
own_daemon() {
  for c in /proc/[0-9]*/environ; do
    grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
    pid=${c#/proc/}; pid=${pid%/environ}
    grep -qa "electron" /proc/"$pid"/cmdline 2>/dev/null || continue
    return 0
  done
  return 1
}
for _ in $(seq 1 40); do
  own_daemon && break
  sleep 1
done
own_daemon \
  || { echo "the browser DAEMON never started. Run it by hand to see why -- the CLI spawns it with" >&2
       echo "stdio ignored, so its crash is invisible. Without DISPLAY it picks the x11 ozone" >&2
       echo "backend and dies with 'Missing X server or \$DISPLAY' (terminal-browser #38)." >&2
       exit 3; }

# PROVE THE DAEMON IS OURS. HerdrTarget::from_env reads HERDR_PANE_ID and HERDR_SOCKET_PATH in the
# DAEMON, which is shared and long-lived: `shutdown` is not instantaneous, so a leftover daemon
# silently serves the page with another pane id and writes frames nowhere near our directory. That
# reads as "the browser refused the fast path" when the truth is "we measured the wrong browser".
# Exit 3 rather than report a false UNMET.
# OWN-DAEMON CHECK, BY AGE NOT BY ENV. The daemon never carries HERDR_PANE_ID in its process
# environment and never will: the CLI forwards the pane env inside the open REQUEST
# ({cmd:"open", tty, argv, env: process.env, cwd, build}), the daemon reads it as
# `message.env ?? {}` and hands it to the engine as sessionEnv. An earlier version of this gate
# asserted the variable in /proc/<daemon>/environ and so failed could-not-run on every run,
# measuring a thing that is false by construction.
DPID=""
for c in /proc/[0-9]*/environ; do
  grep -qz "^XDG_RUNTIME_DIR=$PRIV\$" "$c" 2>/dev/null || continue
  pid=${c#/proc/}; pid=${pid%/environ}
  grep -qa "electron" /proc/"$pid"/cmdline 2>/dev/null || continue
  DPID=$pid; break
done
[ -n "${DPID:-}" ] || { echo "no browser daemon of our own" >&2; exit 3; }
AGE=$(ps -o etimes= -p "$DPID" 2>/dev/null | tr -d ' ')
SINCE=$(( $(date +%s) - T0 ))
if [ -z "${AGE:-}" ] || [ "$AGE" -gt "$SINCE" ]; then
  echo "the daemon (pid $DPID, age ${AGE:-?}s) predates this run (${SINCE}s): it was not spawned" >&2
  echo "by our pane, so its sessionEnv points at someone elses pane" >&2
  exit 3
fi
echo "daemon $DPID is ours (age ${AGE}s of ${SINCE}s)"
sleep 12                                          # frames take several seconds to begin

python3 - "$SOCK" "$PANE" <<'PY'
import socket, json, sys, os, glob
sock, pane = sys.argv[1], sys.argv[2]
def req(o):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(8); s.connect(sock)
    s.sendall((json.dumps(o) + "\n").encode()); b = b""
    while b"\n" not in b:
        d = s.recv(65536)
        if not d: break
        b += d
    s.close(); return json.loads(b.decode().split("\n")[0])
res = req({"id": "i", "method": "pane.graphics.info", "params": {"pane_id": pane}}).get("result", {})
transport = res.get("file_frame_transport")
directory = res.get("file_frame_directory")
print(f"after frames: file_frame_transport={transport!r} directory={directory!r}")
if transport != "direct-kitty":
    print("UNMET: the transport is not advertised, so Herdr::connect returned None and every")
    print("       frame went down the pty as a full-surface escape (herdr #3785 / tb #97)")
    sys.exit(1)
frames = glob.glob(os.path.join(directory, "*")) if directory else []
print(f"frame files in the advertised directory: {len(frames)}")
if not frames:
    print("UNMET: transport advertised but NOTHING was written to the frame directory -- the")
    print("       browser did not adopt the fast path, so the advertisement alone proves nothing")
    sys.exit(1)
print("MET: direct-kitty advertised after frames, and the browser wrote frames as files")
sys.exit(0)
PY
