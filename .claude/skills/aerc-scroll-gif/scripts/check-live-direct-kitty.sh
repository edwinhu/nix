#!/usr/bin/env bash
# Is the LIVE herdr session still on the direct-kitty file transport?
#
# When it is not, every graphics frame goes down the pty as a full-surface kitty escape and herdr
# re-encodes it for the client: measured 24 transmits and 216 MB announced for one 2400px scroll,
# against ZERO on the direct path. Nothing reports the downgrade -- terminal-browser falls back to
# writing VT silently (upstream tb #97, "falling back is what working looks like") -- so this check
# is the only thing that notices.
#
# Cause, for whoever reads this when it fires: herdr negotiates client.direct_graphics once at
# handshake, and a transfer timeout used to clear it permanently (herdr #3785; patched in the fork
# at 4221d4b5 to suspend for 60s instead). A client that has lost it cannot regain it, so the
# remedy is to restart the CLIENT -- close and reopen the terminal window running herdr. Panes live
# in the SERVER process and survive that; do not stop the server, which exits every pane.
#
# Exit 0 on the direct path, 1 degraded, 3 could-not-run.
set -uo pipefail

SOCK=${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}
[ -S "$SOCK" ] || { echo "no herdr socket at $SOCK" >&2; exit 3; }

python3 - "$SOCK" "${HERDR_PANE_ID:-}" <<'PY'
import json, socket, sys
sock, want = sys.argv[1], sys.argv[2]

def req(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8)
    s.connect(sock)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode().split("\n")[0])

try:
    panes = [p["pane_id"] for p in req({"id": "p", "method": "pane.list", "params": {}})["result"]["panes"]]
except Exception as exc:
    print(f"could not list panes: {exc}", file=sys.stderr)
    sys.exit(3)
if not panes:
    print("the session has no panes", file=sys.stderr)
    sys.exit(3)

pane = want if want in panes else panes[0]
try:
    info = req({"id": "i", "method": "pane.graphics.info", "params": {"pane_id": pane}})["result"]
except Exception as exc:
    print(f"could not read pane.graphics.info: {exc}", file=sys.stderr)
    sys.exit(3)

transport = info.get("file_frame_transport")
print(f"pane {pane}: file_frame_transport={transport!r} pixel_mouse={info.get('pixel_mouse')}")
if transport == "direct-kitty":
    print("on the direct file transport")
    sys.exit(0)
print("DEGRADED: no direct-kitty, so every frame goes down the pty as a full surface.")
print("Remedy: restart the herdr CLIENT -- close and reopen the terminal window running herdr.")
print("Panes live in the server and survive it. Do NOT stop the server; that exits every pane.")
sys.exit(1)
PY
