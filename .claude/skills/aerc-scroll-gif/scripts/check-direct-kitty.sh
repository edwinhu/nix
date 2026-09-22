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
  __g=$(pgrep -f "ghostty.*herdr" 2>/dev/null | head -1)
  [ -n "${__g:-}" ] && eval "$(tr '\0' '\n' < /proc/"$__g"/environ \
    | grep -E "^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|DISPLAY|XDG_SESSION_TYPE|GDK_BACKEND)=" \
    | sed 's/^/export /')"
fi
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { echo "no compositor environment to borrow" >&2; exit 3; }

WORK=$(mktemp -d)
cleanup() {
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
setsid env $UNSET "$GH" --class=dev.dkgate -e bash -c "env $UNSET $HERDR_BIN --session $SESSION" \
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
timeout 20 "$TB" shutdown >/dev/null 2>&1
for _ in $(seq 1 15); do
  pgrep -f "[t]erminal-browser/app/electron.*--daemon" >/dev/null 2>&1 || break
  sleep 1
done
for dp in $(pgrep -f "[t]erminal-browser/app/electron.*--daemon" 2>/dev/null); do kill "$dp" 2>/dev/null; done
sleep 2
pgrep -f "[t]erminal-browser/app/electron.*--daemon" >/dev/null 2>&1 \
  && { echo "a browser daemon will not die; it would serve this measurement" >&2; exit 3; }
printf '#!/usr/bin/env bash\nexec %s open file://%s\n' "$TB" "$WORK/page.html" > "$WORK/run.sh"
chmod +x "$WORK/run.sh"
h pane run "$PANE" "$WORK/run.sh" >/dev/null 2>&1

# Wait for the DAEMON, not for any electron: bin/terminal-browser is itself
# `electron cli/dist/main.js`, so a bare app/electron match is satisfied by the CLI and proves
# nothing. The daemon is the process that paints.
for _ in $(seq 1 40); do
  pgrep -f "[t]erminal-browser/app/electron.*--daemon" >/dev/null 2>&1 && break
  sleep 1
done
pgrep -f "[t]erminal-browser/app/electron.*--daemon" >/dev/null 2>&1 \
  || { echo "the browser DAEMON never started. Run it by hand to see why -- the CLI spawns it with" >&2
       echo "stdio ignored, so its crash is invisible. Without DISPLAY it picks the x11 ozone" >&2
       echo "backend and dies with 'Missing X server or \$DISPLAY' (terminal-browser #38)." >&2
       exit 3; }

# PROVE THE DAEMON IS OURS. HerdrTarget::from_env reads HERDR_PANE_ID and HERDR_SOCKET_PATH in the
# DAEMON, which is shared and long-lived: `shutdown` is not instantaneous, so a leftover daemon
# silently serves the page with another pane id and writes frames nowhere near our directory. That
# reads as "the browser refused the fast path" when the truth is "we measured the wrong browser".
# Exit 3 rather than report a false UNMET.
# Electron spawns helper processes (gpu, renderer, zygote) whose command line also carries
# --daemon while their environ is scrubbed, so `head -1` can pick a child and report our own
# daemon as foreign. Scan every candidate and accept if ANY carries our pane id.
DPID=""
CANDIDATES=$(pgrep -f "[t]erminal-browser/app/electron.*--daemon" 2>/dev/null)
[ -n "${CANDIDATES:-}" ] || { echo "no browser daemon to verify" >&2; exit 3; }
for c in $CANDIDATES; do
  cenv=$(tr '\0' '\n' < /proc/"$c"/environ 2>/dev/null)
  cpane=$(printf '%s' "$cenv" | sed -n 's/^HERDR_PANE_ID=//p' | head -1)
  csock=$(printf '%s' "$cenv" | sed -n 's/^HERDR_SOCKET_PATH=//p' | head -1)
  echo "  candidate $c: pane=${cpane:-<unset>}"
  if [ "${cpane:-}" = "$PANE" ] && [ "${csock:-}" = "$SOCK" ]; then DPID=$c; fi
done
if [ -z "${DPID:-}" ]; then
  echo "no daemon carries our pane id ($PANE) and socket; a foreign daemon is serving this" >&2
  echo "measurement, or the browser was launched outside the pane" >&2
  exit 3
fi
echo "daemon $DPID verified: pane=$DPANE"
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
