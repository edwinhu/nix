# Omarchy (Arch Linux) on Framework Desktop (AMD Ryzen AI Max, x86_64)
# Minimal nix config - dotfiles managed separately.
# Modeled on hosts/linux/alarm (the aarch64/Asahi Omarchy host); the two share
# the same Omarchy desktop-entry + package set and differ only by architecture,
# which is handled in flake.nix (userHosts + the doublecmd/beeper overlays).
{ config, pkgs, lib, user, userInfo, self, ... }:

let
  iconDir = ../../../modules/linux/desktop-icons;

  # aerc's text/html filter: chawan in DUMP mode, network-isolated.
  #
  # chawan (not w3m) because it has a real CSS engine and honours a newsletter's
  # own column layout instead of flattening it — measured 29ms vs w3m's 21ms on a
  # 142KB newsletter, so the fidelity is nearly free. Dump mode renders exactly
  # the same as the interactive mode did; it is the SAME renderer, so nothing
  # about the layout changes.
  #
  # INLINE IMAGES WERE TRIED AND ARE IMPOSSIBLE HERE. Do not re-attempt without
  # reading this. aerc pipes the message part in on STDIN, so chawan treats the
  # document as `<*stdin*>` — and chawan only fetches remote images for documents
  # that are THEMSELVES remote. Every image in an email is a remote URL, so none
  # of them ever load. Measured three ways: an https document loaded 52/56
  # images, the same markup as a file:// document loaded 0/1, and via stdin
  # (aerc's actual path) every image rendered as `[img]`. There is no config to
  # relax it — `buffer.images` is only on/off, and siteconf matches on URL, which
  # a stdin document has none of. Interactive mode, forced image-mode, and
  # hardcoded cell geometry were each tried and none of them address this.
  #
  # Consequences of dump mode, all of them wins given the above:
  #   - aerc's own keybindings work; chawan no longer owns input until `q`.
  #   - Scrolling is aerc's pager, so no chawan key rebinding is needed. (The
  #     interactive version had to remap j/k/arrows/space because chawan's own
  #     scroll keys — J/K, C-e/C-y — are all swallowed by aerc's [view] binds.)
  #   - `unshare --net` is back, which is what blocks tracking pixels. It also
  #     keeps chawan fast: with network access it tries to fetch remote images
  #     and fonts and hangs for minutes on a real newsletter.
  #
  # -I/-O UTF-8 are NOT optional; dropping them is what produced mojibake
  # (a curly apostrophe rendering as "\u00e2\u20ac\u2122"). aerc decodes a part to UTF-8
  # before piping it here, but plenty of marketing mail carries a <meta> that
  # still DECLARES a legacy charset, and chawan believes the declaration over
  # the bytes — decoding UTF-8 as windows-1252. Reproduced exactly: a page
  # declaring windows-1252 while holding UTF-8 bytes came out as the byte
  # sequence C3 A2 E2 82 AC E2 84 A2. aerc's own shipped w3m filter passes both
  # flags for precisely this reason; this filter replaced it and initially did
  # not.
  #
  # STYLING AND WIDTH MUST BE FORCED IN DUMP MODE, or the output is plain
  # monochrome text wrapped at 80 columns — every style chawan's CSS engine
  # computed is thrown away on the way out. `-d` writes to a pipe, so chawan
  # cannot detect the terminal and its "auto" settings resolve to nothing:
  #   - color-mode        → monochrome. Measured: 0 escape sequences in the
  #                         output; with true-color, 1632.
  #   - format-mode       → no attributes. color-mode alone is NOT enough —
  #                         with only colour forced, bold/italic/underline are
  #                         all still absent; this array is what restores them.
  #   - columns           → the documented 80 fallback, while the message view
  #                         is ~130 wide, so everything was squeezed into 80
  #                         columns with heavy padding.
  # 120 leaves margin inside a 152-column terminal minus aerc's 22-column
  # sidebar. aerc's pager (`less -Rc`) passes the escapes through.
  #
  # stdin: aerc pipes the part in, so chawan reads `-`. chawan BLOCKS on an open
  # stdin it has not been told to read, so the `-` is load-bearing.
  aercChawanHtml = pkgs.writeShellScript "aerc-chawan-html" ''
    set -u
    set -- ${pkgs.chawan}/bin/cha -d -T text/html -I UTF-8 -O UTF-8 \
      -o 'display.color-mode="true-color"' \
      -o 'display.format-mode=["bold","italic","underline","reverse","strike"]' \
      -o 'display.columns=120' \
      -o 'display.force-columns=true' \
      -
    if command -v ${pkgs.util-linux}/bin/unshare >/dev/null 2>&1; then
      set -- ${pkgs.util-linux}/bin/unshare --map-root-user --net "$@"
    fi
    exec "$@"
  '';

  # Python helper for the PDF preview filter: speaks herdr's socket API.
  aercPdfHelper = pkgs.writeText "herdr-graphics.py" ''
"""herdr pane-graphics helper for the aerc PDF preview filter.

Modes:

  info <sock> <pane_id>
      Print "<cell_w> <cell_h> <pane_cols> <pane_rows>" and exit 0, or exit 1
      on any error. This is the GATE -- see fact 1.

  stream <sock> <pane_id> <token> <status_file>
      Read frame requests from stdin, one per line:
          <png_path> <grid_cols> <grid_rows> <viewport_cols>
      and keep the image on screen for as long as this process lives AND the
      filter's indicator line (identified by <token>) is actually visible in
      the pane. Writes "shown" / "hidden" / "blocked" to <status_file> so the
      filter can tell the user when it is waiting on another part's stream.

      Note the filter does NOT pass a row/column: the helper MEASURES where the
      indicator actually is (fact 6) and derives placement from that.

FACTS ESTABLISHED THE HARD WAY. Do not rediscover these.

1. pane.graphics.info IS THE ONLY HONEST GATE. pane.graphics.set returns
   {"result":{"type":"ok"}} even on a pane that cannot render anything -- it
   stores the image regardless of whether any client can composite it. info()
   is the only call that fails loudly (cell_size_unavailable).

2. USE THE STREAM, NOT set(). set() rejects image data over 512 KiB
   ("image_too_large"), and a full-pane page at exact cell resolution is over
   that, so set() cannot do this job at all. The stream has no such limit
   (verified: a 585,198-byte PNG that set() refuses transmits fine). The stream
   is also connection-bound -- when this process dies, including SIGKILL, herdr
   emits a kitty delete for the image.

3. AERC DOES NOT KILL THE FILTER ON A PART SWITCH. Measured: Ctrl+j/Ctrl+k
   switches the pane to another part, no delete is emitted, and both the filter
   and this helper stay alive. So fact 2's teardown never fires, and without the
   watcher below the page stays painted over whatever part you switched to.

4. ONLY THE STREAM OWNER CAN CLEAR A STREAM-OWNED IMAGE, AND THERE IS EXACTLY
   ONE STREAM PER PANE. pane.graphics.clear from another connection returns
   stream_conflict and does nothing. "Hide" is therefore implemented by closing
   our own stream (herdr turns that into a delete) and "restore" by reopening.

5. A MESSAGE WITH TWO PDF PARTS RUNS TWO FILTERS AT ONCE, COMPETING FOR THAT
   ONE STREAM. aerc starts a filter per part and keeps them all alive. The
   loser gets stream_conflict. It must NOT treat that as fatal: it has to keep
   retrying and take the stream over once the other part is hidden and releases
   it. That is why the stream is opened lazily in the watcher, not at startup,
   and why the token must be UNIQUE PER PROCESS -- with a shared marker each
   helper sees the other's identical indicator line, concludes it is still
   visible, never releases, and the two deadlock.

6. DO NOT COMPUTE THE VERTICAL OFFSET ARITHMETICALLY. aerc's parts list grows
   with the number of attachments, so the chrome below the viewer is not a
   fixed height: measured 4 rows for text+2 PDFs (parts list + status) versus 1
   for a lone PDF. The old `pane_rows - term_rows - 1` overshot by exactly the
   extra part lines and pushed the page down the pane. We locate the token's
   ACTUAL row in the pane text and place the image directly under it, which is
   correct for any layout.
"""
import json
import socket
import struct
import sys
import threading
import time

POLL_SECONDS = 0.4
INDENT = 2          # our indicator line starts with this many spaces


def connect(sock_path):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(sock_path)
    return s


def recv_line(s):
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise EOFError("server closed connection")
        buf += chunk
    return buf.split(b"\n", 1)[0].decode()


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    return struct.unpack(">II", data[16:24])


def rpc(sock_path, method, params):
    """One-shot request on its own connection. The streaming socket cannot be
    reused for this: once upgraded it only accepts frame headers."""
    s = connect(sock_path)
    try:
        s.sendall((json.dumps({"id": "r", "method": method, "params": params}) + "\n").encode())
        return json.loads(recv_line(s))
    finally:
        s.close()


def open_stream(sock_path, pane_id):
    s = connect(sock_path)
    s.sendall((json.dumps({"id": "s", "method": "pane.graphics.stream",
                           "params": {"pane_id": pane_id}}) + "\n").encode())
    reply = json.loads(recv_line(s))
    if "error" in reply:
        s.close()
        raise OSError(reply["error"].get("code", "stream_open_failed"))
    # Now a frame transport, not JSON-RPC: a header line then exactly
    # data_length raw bytes. It never acks, so errors are invisible here --
    # which is why info() gates first.
    s.settimeout(None)
    return s


def mode_info(sock_path, pane_id):
    reply = rpc(sock_path, "pane.graphics.info", {"pane_id": pane_id})
    if "error" in reply:
        sys.stderr.write("herdr graphics unavailable: %s\n"
                         % reply["error"].get("code", "unknown"))
        return 1
    r = reply["result"]
    cw, ch = int(r["cell_width_px"]), int(r["cell_height_px"])
    if cw <= 0 or ch <= 0:
        sys.stderr.write("herdr graphics unavailable: zero cell size\n")
        return 1

    reply = rpc(sock_path, "pane.layout", {})
    if "error" in reply:
        sys.stderr.write("pane layout unavailable: %s\n"
                         % reply["error"].get("code", "unknown"))
        return 1
    layout = reply["result"]["layout"]
    rect = None
    for p in layout.get("panes", []):
        if p.get("pane_id") == pane_id:
            rect = p["rect"]
    if rect is None:
        rect = layout.get("area")
    if not rect:
        sys.stderr.write("pane layout has no rect for %s\n" % pane_id)
        return 1
    print(cw, ch, int(rect["width"]), int(rect["height"]))
    return 0


def find_token(sock_path, pane_id, token):
    """Return (row, col) of our indicator line, or None if it is not on screen.

    col is the pane column our terminal's column 0 maps to, recovered from the
    indicator's leading whitespace.
    """
    reply = rpc(sock_path, "pane.read",
                {"pane_id": pane_id, "source": "visible", "format": "text"})
    text = reply.get("result", {}).get("read", {}).get("text")
    if not text:
        return None
    for row, line in enumerate(text.split("\n")):
        if token in line:
            return row, max(0, (len(line) - len(line.lstrip(" "))) - INDENT)
    return None


def mode_stream(sock_path, pane_id, token, status_file):
    conn = {"s": None}
    want = {"frame": None}      # (png_path, gc, gr, img_cols)
    sent = {"key": None}
    status = [None]

    def write_status(value):
        if status_file and value != status[0]:
            try:
                with open(status_file, "w") as fh:
                    fh.write(value + "\n")
            except OSError:
                pass
            status[0] = value

    def send_frame(path, gc, gr, col, row):
        with open(path, "rb") as fh:
            data = fh.read()
        w, h = png_size(data)
        header = {
            "format": "png", "image_width": w, "image_height": h,
            "data_length": len(data),
            "placement": {"grid_cols": int(gc), "grid_rows": int(gr),
                          "viewport_col": int(col), "viewport_row": int(row)},
        }
        conn["s"].sendall((json.dumps(header) + "\n").encode())
        conn["s"].sendall(data)

    def release():
        if conn["s"] is not None:
            try:
                conn["s"].close()
            except OSError:
                pass
            conn["s"] = None
            sent["key"] = None

    def watcher():
        while True:
            time.sleep(POLL_SECONDS)
            frame = want["frame"]
            if frame is None:
                continue
            try:
                pos = find_token(sock_path, pane_id, token)
            except Exception:
                continue

            if pos is None:                      # we are not the displayed part
                release()
                write_status("hidden")
                continue

            row, col = pos
            path, gc, gr, img_cols = frame
            place_col = col + max(0, (int(img_cols) - int(gc)) // 2)
            place_row = row + 1                  # directly under the indicator
            key = (path, gc, gr, place_col, place_row)

            if conn["s"] is None:
                try:
                    conn["s"] = open_stream(sock_path, pane_id)
                except OSError:
                    # Another part's filter holds the single per-pane stream.
                    # Keep retrying; it releases as soon as it is hidden.
                    write_status("blocked")
                    continue
                sent["key"] = None
            if key != sent["key"]:
                try:
                    send_frame(path, gc, gr, place_col, place_row)
                    sent["key"] = key
                except (OSError, ValueError, struct.error):
                    release()
                    write_status("blocked")
                    continue
            write_status("shown")

    threading.Thread(target=watcher, daemon=True).start()

    sys.stdout.write("ready\n")
    sys.stdout.flush()
    for line in sys.stdin:
        parts = line.split()
        if len(parts) != 4:
            continue
        want["frame"] = tuple(parts)
        sent["key"] = None                       # force a resend for the new page
    return 0


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: herdr_graphics.py info <sock> <pane>\n"
            "       herdr_graphics.py stream <sock> <pane> <token> <status_file>\n")
        return 2
    mode, sock_path, pane_id = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        if mode == "info":
            return mode_info(sock_path, pane_id)
        if mode == "stream":
            token = sys.argv[4] if len(sys.argv) > 4 else None
            status_file = sys.argv[5] if len(sys.argv) > 5 else None
            if not token:
                sys.stderr.write("stream mode requires a token\n")
                return 2
            return mode_stream(sock_path, pane_id, token, status_file)
    except (OSError, EOFError, ValueError) as exc:
        sys.stderr.write("herdr graphics error: %s\n" % exc)
        return 1
    sys.stderr.write("unknown mode %r\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main())
  '';

  aercPdfPreview = pkgs.writeShellScript "aerc-pdf-preview" ''
    export PATH=${lib.makeBinPath [ pkgs.poppler-utils pkgs.python3 pkgs.coreutils pkgs.gawk pkgs.ncurses ]}:$PATH
    export AERC_PDF_HELPER=${aercPdfHelper}
# aerc `!` filter: inline PDF page preview, rendered by herdr's pane-graphics
# API rather than by anything aerc can see.
#
# WHY THIS WORKS WHERE EVERY IN-BAND APPROACH FAILED
# --------------------------------------------------
# aerc's embedded terminal PARSES AND DISCARDS kitty graphics APC sequences, so
# a filter can never draw an image by writing escapes to its own stdout. This
# filter never tries: it asks herdr, over herdr's unix socket, to composite the
# image into the PANE. The bytes never pass through aerc. Placement is in grid
# cells relative to the pane, so none of the pixel geometry that killed the
# ueberzugpp attempt (pixels-per-cell, hosting window rect) is needed.
#
# NINE FACTS THAT COST A LOT OF TIME TO ESTABLISH -- do not rediscover them:
#
# 1. pane.graphics.info IS THE ONLY HONEST GATE. pane.graphics.set returns
#    {"result":{"type":"ok"}} even for a pane that cannot possibly render --
#    it stores the image regardless. info() is the only call that fails loudly
#    (cell_size_unavailable) when nothing can be composited.
#
# 2. THE GATE NEEDS A POST-FLAG herdr CLIENT. Cell size is probed from the host
#    terminal (CSI 16t) by each herdr CLIENT at client startup, and only when
#    experimental.kitty_graphics is already enabled. A client that started
#    before the flag was set reports cell_width_px=0 forever, and
#    `herdr server reload-config` does NOT fix it -- the client process itself
#    has to restart. Net effect: this filter degrades to the notice until the
#    user's own herdr client has been restarted at least once since the flag
#    went on. That is expected, and it is why the fallback has to be good.
#    (An earlier theory that the client's viewport had to match the layout's
#    was wrong; the real mechanism is the race in fact 9.)
#
# 3. herdr CROPS, IT DOES NOT SCALE. The placement's grid_cols/grid_rows set
#    kitty's SOURCE-CROP rect to grid_cols*cell_w x grid_rows*cell_h. Handing
#    it an image larger than that shows the top-left corner of the page; handing
#    it a smaller one leaves the rest of the rect stale. So the page MUST be
#    rendered at exactly grid_cols*cell_w x grid_rows*cell_h pixels. Rendering
#    small and expecting herdr to scale up does not work.
#
# 4. set() CAPS IMAGE DATA AT 512 KiB; THE STREAM DOES NOT. A full-pane page at
#    exact cell resolution exceeds the cap, so set() cannot do this job at all.
#    The stream also ties the image to the connection: when the streaming
#    process dies -- including SIGKILL -- herdr deletes the image by itself.
#    That is why the helper is held open for the filter's whole life instead of
#    firing one request and exiting. It makes q, :close and aerc exiting clean
#    with no signal from aerc.
#
# 5. AERC DOES NOT KILL THE FILTER ON A PART SWITCH, so fact 4 does not cover
#    the case that matters most. Measured: Ctrl+k moves the pane to another
#    part, no delete is emitted, and both this script and the helper stay
#    alive -- the page stays painted over whatever you switched to. aerc also
#    REUSES the same filter when you switch back. The only observable signal is
#    our own indicator line leaving the pane, so the helper polls pane.read for
#    TOKEN. Hiding must be done BY THE STREAM OWNER: pane.graphics.clear from
#    any other connection returns stream_conflict and does nothing.
#
# 6. TWO PDF ATTACHMENTS => TWO FILTERS COMPETING FOR ONE STREAM. aerc starts a
#    filter per part and keeps them all running, but herdr allows exactly one
#    graphics stream per pane. The loser must NOT give up: it retries until the
#    other part is hidden and releases. Hence TOKEN is unique per process (a
#    shared marker makes each helper see the other's identical indicator, never
#    release, and deadlock), and "cannot get the stream" shows the notice as a
#    WAITING state that clears itself, not a permanent failure.
#
# 7. THE VERTICAL OFFSET MUST BE MEASURED, NOT COMPUTED. aerc's parts list grows
#    with the attachment count, so the chrome under the viewer is not fixed:
#    4 rows for text+2 PDFs versus 1 for a lone PDF. The old
#    `pane_rows - term_rows - 1` overshot by exactly the extra part lines and
#    pushed the page down the pane. The helper now finds TOKEN's real row.
#
# 8. DO NOT TRY TO DEBUG THIS WITH herdr's TRACE LOGGING. The kitty compositor
#    has an inviting trace vocabulary (`clipped_placement: success|...`) and the
#    callsite symbols are in the nixpkgs binary, but the build is tracing's
#    release_max_level_debug, so those events can NEVER fire (HERDR_LOG=trace
#    yields 0 TRACE lines). To see whether an image reached the terminal, run
#    the herdr client under a pty relay and read the kitty APC on the wire
#    (a=t transmit / a=p place / a=d delete).
#
# 9. THE GATE IS RACY WHILE ANY PRE-FLAG CLIENT IS ATTACHED. herdr keeps ONE
#    global host cell size and every client rewrites it, so a client reporting
#    cell_width_px=0 re-reports it on every new client connect and can clobber
#    a good value. A non-zero but WRONG value is possible too, from a client
#    with a different cell size (e.g. an SSH client at 8x16 rather than the
#    local 16x36) -- and since herdr crops rather than scales, that renders at
#    the wrong scale rather than failing cleanly.
set -u

TMP=$(mktemp -d) || exit 0
HELPER_PID=""
cleanup() {
  [ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
  exec 3>&- 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM HUP

cat > "$TMP/in.pdf"

# ---------------------------------------------------------------- notice path
# The accepted floor. Reached whenever the preview cannot be trusted -- never
# leave the pane blank, which is the failure mode already shipped once.
# Under the `!` filter form aerc closes the terminal as soon as we exit, so the
# notice has to be held on screen rather than printed and abandoned.
notice() {
  local pages size
  pages=$(pdfinfo "$TMP/in.pdf" 2>/dev/null | awk '/^Pages:/{print $2}')
  size=$(du -h "$TMP/in.pdf" 2>/dev/null | awk '{print $1}')
  if [ -z "''${pages:-}" ]; then
    printf '  Not a readable PDF. Press o to open it anyway, or | to pipe it.\n'
  else
    printf '  PDF — %s pages, %sB. Press o to open in hylo.\n' "''${pages:-?}" "''${size:-?}"
  fi
  [ -n "''${1:-}" ] && printf '  (inline preview unavailable: %s)\n' "$1"
  # Hold until aerc tears the viewer down (:close, q, or aerc exiting). Note
  # a part switch does NOT kill us -- see fact 5 -- but the notice is plain
  # text, so a stale one is harmless where a stale image would not be.
  # Keys come from /dev/tty, NOT stdin -- stdin is the PDF pipe and is at EOF,
  # so reading it here would return instantly and blank the pane.
  if [ -r /dev/tty ]; then
    while IFS= read -r -N1 _key < /dev/tty; do :; done
  fi
  exit 0
}

# ---------------------------------------------------------------------- gate
HELPER="''${AERC_PDF_HELPER:-}"
[ -n "$HELPER" ] || HELPER="$(dirname "$0")/herdr_graphics.py"

command -v pdfinfo  >/dev/null 2>&1 || notice "pdfinfo missing"
command -v pdftoppm >/dev/null 2>&1 || notice "pdftoppm missing"
command -v python3  >/dev/null 2>&1 || notice "python3 missing"
[ -r "$HELPER" ]                    || notice "helper missing"
[ -n "''${HERDR_PANE_ID:-}" ]         || notice "not in a herdr pane"

SOCK="''${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
[ -S "$SOCK" ] || notice "no herdr socket"

INFO=$(python3 "$HELPER" info "$SOCK" "$HERDR_PANE_ID" 2>/dev/null) || notice "graphics unavailable"
read -r CELL_W CELL_H PANE_COLS PANE_ROWS <<< "$INFO"
case "$CELL_W$CELL_H$PANE_COLS$PANE_ROWS" in '''|*[!0-9]*) notice "bad geometry" ;; esac

INFO_PDF=$(pdfinfo "$TMP/in.pdf" 2>/dev/null) || notice "unreadable PDF"
NPAGES=$(printf '%s\n' "$INFO_PDF" | awk '/^Pages:/{print $2}')
SIZE=$(du -h "$TMP/in.pdf" 2>/dev/null | awk '{print $1}')
[ -n "''${NPAGES:-}" ] || notice "unreadable PDF"
ASPECT=$(printf '%s\n' "$INFO_PDF" | awk '/^Page size:/{if ($5>0) printf "%.6f", $3/$5}')
[ -n "''${ASPECT:-}" ] || ASPECT=0.772727

# ------------------------------------------------------------------ geometry
# The filter's own terminal is aerc's message-viewer sub-rect, somewhere inside
# the herdr pane. Placement is pane-relative, so we need that offset. aerc puts
# the viewer flush to the right edge of the pane, with the status line below it.
TERM_COLS=''${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
TERM_ROWS=''${LINES:-$(tput lines 2>/dev/null || echo 24)}


# Row 0 of our terminal keeps the page indicator; the image occupies the rest.
# We compute only the SIZE here. The POSITION is measured by the helper from
# where our indicator actually lands in the pane (fact 7).
PLACE=$(python3 -c '
import sys
cell_w, cell_h, term_cols, term_rows, aspect = (
    int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
    float(sys.argv[5]))

img_cols = term_cols
img_rows = term_rows - 1          # row 0 is the indicator line
if img_cols < 4 or img_rows < 4:
    raise SystemExit(1)

avail_w, avail_h = img_cols * cell_w, img_rows * cell_h
h = avail_h
w = h * aspect
if w > avail_w:
    w = avail_w
    h = w / aspect

# Snap to whole cells so the crop rect and the rendered image agree exactly.
gc = max(1, min(img_cols, int(w // cell_w)))
gr = max(1, min(img_rows, int(h // cell_h)))
print(gc, gr, img_cols, gc * cell_w, gr * cell_h)
' "$CELL_W" "$CELL_H" "$TERM_COLS" "$TERM_ROWS" "$ASPECT" 2>/dev/null) \
  || notice "pane too small"
read -r GC GR IMG_COLS PX_W PX_H <<< "$PLACE"

# -------------------------------------------------------------------- stream
FIFO="$TMP/ctl"
STATUS="$TMP/status"
mkfifo "$FIFO" || notice "no fifo"
# TOKEN must be UNIQUE PER PROCESS (fact 6): two PDF attachments mean two
# filters running at once, and with a shared marker each helper would see the
# other's identical indicator line, believe itself still visible, never release
# the single per-pane stream, and deadlock. $$ plus a clock read is enough.
# $$ is unique among the concurrently-live filters, which is all that matters;
# the brackets keep it from matching digits elsewhere in the pane text.
TOKEN="[$$]"
python3 "$HELPER" stream "$SOCK" "$HERDR_PANE_ID" "$TOKEN" "$STATUS" \
  < "$FIFO" > "$TMP/ready" 2>"''${AERC_PDF_DEBUG:-/dev/null}" &
HELPER_PID=$!
exec 3> "$FIFO"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$TMP/ready" ] && break
  kill -0 "$HELPER_PID" 2>/dev/null || break
  sleep 0.1
done
[ -s "$TMP/ready" ] || notice "helper did not start"

# --------------------------------------------------------------------- pages
render_page() {
  local n="$1" out="$TMP/pg-$1.png"
  if [ ! -f "$out" ]; then
    # Exact pixel size: herdr crops to grid_cols*cell_w x grid_rows*cell_h, so
    # anything else shows a cropped edge (fact 3).
    pdftoppm -png -f "$n" -l "$n" -scale-to-x "$PX_W" -scale-to-y "$PX_H" \
      "$TMP/in.pdf" "$TMP/raw-$n" 2>/dev/null || return 1
    mv "$TMP/raw-$n"*.png "$out" 2>/dev/null || return 1
  fi
  printf '%s %s %s %s\n' "$out" "$GC" "$GR" "$IMG_COLS" >&3
}

page=1
last_state=""
draw() {
  local state="$1"
  printf '\033[2J\033[H  page %s/%s   j/k page   q dismiss\033[2;90m %s\033[0m\n' \
    "$page" "$NPAGES" "$TOKEN"
  # Never a silent blank pane: while another part's filter holds the stream we
  # show the notice, and it clears itself the moment we get the image up.
  if [ "$state" != "shown" ]; then
    printf '\n  PDF — %s pages, %sB. Press o to open in hylo.\n' "$NPAGES" "$SIZE"
    [ "$state" = "blocked" ] && \
      printf '  (waiting for the other attachment'\'''s preview to release…)\n'
  fi
  last_state="$state"
}

show() {
  if ! render_page "$page"; then
    printf '\033[2J\033[H  page %s: render failed\n' "$page"; return
  fi
  draw "''${last_state:-pending}"
}
show

# Keys from /dev/tty: stdin is the PDF pipe (already drained), so reading it
# would spin at EOF and tear the preview down immediately. The 1s timeout also
# drives the status poll, so a waiting notice clears once the image appears.
if [ -r /dev/tty ]; then
  while true; do
    if IFS= read -r -N1 -t 1 key < /dev/tty; then
      case "$key" in
        j|n) [ "$page" -lt "$NPAGES" ] && { page=$((page + 1)); show; } ;;
        k|p) [ "$page" -gt 1 ] && { page=$((page - 1)); show; } ;;
        q) break ;;
      esac
    else
      kill -0 "$HELPER_PID" 2>/dev/null || break
      state=$(cat "$STATUS" 2>/dev/null)
      [ -n "$state" ] && [ "$state" != "$last_state" ] && draw "$state"
    fi
  done
else
  while kill -0 "$HELPER_PID" 2>/dev/null; do sleep 1; done
fi
exit 0
  '';

  # aerc's application/pdf filter: extracted text, not a rendered page.
  #
  # This is a deliberate retreat from a working inline image preview, because
  # the image preview cannot work WHERE THIS USER ACTUALLY RUNS AERC.
  #
  # Nothing in-band survives. aerc's embedded terminal (the `!` filter form)
  # PARSES AND DISCARDS kitty graphics APC sequences rather than passing them
  # to Ghostty — measured with a hand-written APC, no terminal probing in the
  # path: the identical byte stream renders in a bare Ghostty and renders
  # NOTHING inside aerc. `chafa -f kitty` HANGS FOREVER under aerc on a
  # /dev/tty probe aerc never answers; `chafa -f sixel` exits 0 and draws
  # nothing (this Ghostty build has no sixel); `chafa -f symbols` renders only
  # a text-cell smear. This is why yazi and elio manage inline images and aerc
  # cannot: they own the TTY and write APC straight to it, whereas aerc
  # interposes an emulator that eats the escape.
  #
  # ueberzugpp DOES work around that — it paints in its own Hyprland window,
  # so aerc's emulator never gets a say — and a full implementation was built
  # and verified: centred, aspect-correct, j/k paging, tracking move/resize,
  # clean on message-switch and quit. It is not shipped, because placing that
  # overlay needs three inputs and TWO OF THEM DO NOT EXIST inside a terminal
  # multiplexer, which is how this user runs aerc (herdr):
  #   - pane rect in cells:  available (HERDR_* env survives into the filter)
  #   - pixels per cell:     NOT available — aerc's embedded terminal answers
  #                          DA1 but returns empty for CSI 16t / 14t / 18t
  #   - hosting window rect: NOT available — process ancestry from a herdr pane
  #                          ends at the herdr systemd service, so no
  #                          window-owning process is ever in the chain;
  #                          `hyprctl activewindow` is a guess and in testing
  #                          returned an unrelated Chromium window
  # The observable result was a ~2.4x horizontal scale error and a blank pane.
  # A guarded version that detects the multiplexer and degrades would take the
  # text path 100% of the time here, so it would be dead weight.
  #
  # So this filter renders NO page and dumps NO text — extracted text was
  # explicitly not wanted, and it is the wrong shape for a PDF anyway (columns
  # interleave, figures and tables vanish). It prints one line of orientation
  # and gets out of the way; `o` opens the real document in hylo, which works
  # fine from a herdr pane. Its only job over having no filter at all is
  # replacing aerc's "No filter configured for this mimetype" menu with the
  # page count, the size, and the keystroke that actually helps.
  aercPdfText = pkgs.writeShellScript "aerc-pdf-notice" ''
    set -u
    tmp=$(${pkgs.coreutils}/bin/mktemp) || exit 0
    trap 'rm -f "$tmp"' EXIT INT TERM HUP
    ${pkgs.coreutils}/bin/cat > "$tmp"

    info=$(${pkgs.poppler-utils}/bin/pdfinfo "$tmp" 2>/dev/null)
    if [ -z "$info" ]; then
      echo "  Not a readable PDF. Press o to open it anyway, or | to pipe it."
      exit 0
    fi
    pages=$(printf '%s\n' "$info" | ${pkgs.gawk}/bin/awk '/^Pages:/{print $2}')
    size=$(${pkgs.coreutils}/bin/du -h "$tmp" | ${pkgs.gawk}/bin/awk '{print $1}')
    printf '  PDF — %s pages, %sB. Press o to open in hylo.\n' \
      "''${pages:-?}" "$size"
  '';

  # Brother DS-740D (retail name: DS-7400) sheet-fed scanner — USB 04f9:0469.
  # NONE of Brother's shipped backends support this model out of the box:
  #   - brscan5 (what the DS-740D download page offers) has no model-table entry
  #     for 0x0469, so it never even detects the scanner.
  #   - brscan4 detects it generically ("*DS-740D") but has no scan profile, so
  #     it starts the feed motor, fails the image read, and jams the feeder.
  #   - dsseries (1.0.5) is the older 0x60xx DSmobile generation.
  # Fix (verified on-device with a clean duplex-ADF scan): PATCH brscan5's model
  # table to map 0x0469 onto the ADS-1250W protocol profile (`315,1`) — the
  # compact-document-scanner engine drives the DS-740D correctly. `brscan5Patched`
  # is pkgs.brscan5 with that one row added to brscan5.ini + models/brscan5ext_2.ini.
  #
  # `brscan` = scanimage wrapped with the brother5 backend env. The backend reads
  # its model tables from the hard-coded /etc/opt/brother/scanner paths, symlinked
  # to this patched store copy by the one-time root step (see home.packages).
  # Named `brscan` (not `scanimage`) so it never shadows pacman's sane.
  #
  # ⚠️ The DS-740D is unstable/undriveable at USB 3 SuperSpeed (spontaneous
  # disconnects; "Error during device I/O" on read). It MUST run at USB 2.0 —
  # forced by disabling the SuperSpeed side of its root port; see the
  # ds740d-force-usb2 systemd service one-time install below.
  brscan5Patched = pkgs.brscan5.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      cfg=$out/opt/brother/scanner/brscan5
      # Map the DS-740D (0x0469) onto the ADS-1250W (315) protocol profile.
      sed -i '/0x045a,315,1,"ADS-1250W"/a 0x0469,315,1,"DS-740D"' \
        "$cfg/models/brscan5ext_2.ini"
      sed -i '/^\[Support Model\]/a 0x0469,315,1,"DS-740D"' "$cfg/brscan5.ini"
    '';
  });
  brscanBackends =
    "${brscan5Patched}/lib/sane:${brscan5Patched}/opt/brother/scanner/brscan5:${pkgs.sane-backends}/lib/sane";
  brscanConfigDir = pkgs.writeTextDir "dll.conf" "brother5\n";
  brscan = pkgs.writeShellScriptBin "brscan" ''
    export LD_LIBRARY_PATH="${brscanBackends}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export SANE_CONFIG_DIR="${brscanConfigDir}"
    exec ${pkgs.sane-backends}/bin/scanimage "$@"
  '';
  # brscan-pdf: batch-scan the whole ADF into a single PDF (JPEG pages embedded
  # losslessly by img2pdf → small multi-page PDFs). The TUI's PDF engine — not on
  # PATH; driven via env: SCAN_DPI, SCAN_MODE, SCAN_DUPLEX=1. Usage: `brscan-pdf [out.pdf]`.
  # tel: link handler — opens the number in the Google Voice web app (see the
  # google-voice desktop entry below, which registers it for x-scheme-handler/tel).
  # Script lives in files/ rather than inline so its ${…} bash expansions don't
  # need nix escaping.
  telGvoice = pkgs.writeShellScriptBin "tel-gvoice" ''
    exec ${pkgs.bash}/bin/bash ${./files/tel-gvoice} "$@"
  '';
  brscanPdf = pkgs.writeShellScriptBin "brscan-pdf" ''
    set -uo pipefail
    export LD_LIBRARY_PATH="${brscanBackends}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export SANE_CONFIG_DIR="${brscanConfigDir}"
    out="''${1:-scan-$(date +%Y%m%d-%H%M%S).pdf}"
    dev=$(${pkgs.sane-backends}/bin/scanimage -L 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -oE 'brother5:[^ ]+' | head -1 | tr -d "\`'")
    if [ -z "$dev" ]; then echo "brscan-pdf: DS-740D not found (brscan -L)"; exit 1; fi
    src="Automatic Document Feeder(left aligned)"
    [ -n "''${SCAN_DUPLEX:-}" ] && src="Automatic Document Feeder(left aligned,Duplex)"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    # batch mode returns non-zero when the feeder empties — that's normal.
    ${pkgs.sane-backends}/bin/scanimage -d "$dev" --source "$src" \
      --mode "''${SCAN_MODE:-24bit Color[Fast]}" --resolution "''${SCAN_DPI:-300}" \
      --format=jpeg --batch="$tmp/p%04d.jpg" >/dev/null 2>&1 || true
    n=$(ls "$tmp"/p*.jpg 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then echo "brscan-pdf: no pages scanned (feeder empty / jam?)"; exit 1; fi
    ${pkgs.img2pdf}/bin/img2pdf "$tmp"/p*.jpg -o "$out"
    echo "brscan-pdf: wrote $out ($n page(s))"
  '';
  # brscan-tui: full-screen scan dashboard (charmbracelet/bubbletea), styled
  # after bluetui — rounded-border panel, selected-row highlight, keybind bar.
  # Colors use the ANSI 16-palette so they follow the terminal theme (Catppuccin)
  # automatically. Go source in files/brscan-tui/; shells out to the brscan +
  # brscan-pdf wrappers (put on PATH by wrapProgram below).
  brscanTui = pkgs.buildGoModule {
    pname = "brscan-tui";
    version = "0.1.0";
    src = ./files/brscan-tui;
    vendorHash = "sha256-bZBlez8lM1Z4OabsVtcGJIpM1wRsKXC6FGs8HBcSPrs=";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postInstall = ''
      wrapProgram $out/bin/brscan-tui \
        --prefix PATH : ${lib.makeBinPath [ brscan brscanPdf ]}
    '';
  };

  # brscan-skey: Brother's Scan Key daemon — watches the DS-740D's Start button
  # (over USB via libusb polling) and runs an action on press. Verified working
  # on the DS-740D. Not in nixpkgs; packaged from Brother's .deb, autopatchelf'd
  # (the daemon dlopens libusb at runtime → the LD_LIBRARY_PATH wrap; skey-scanimage
  # links libsane → sane-backends). The config is baked to run the scan-to-PDF
  # action below on every button function. Runs via the brscan-skey user service.
  #
  # Button action: scan the whole feeder (duplex) → ~/scans/scan-<ts>.pdf.
  brscanSkeyAction = pkgs.writeShellScript "brscan-skey-scan" ''
    mkdir -p "$HOME/scans"
    SCAN_DUPLEX=1 SCAN_DPI=300 SCAN_MODE='24bit Color[Fast]' \
      ${brscanPdf}/bin/brscan-pdf "$HOME/scans/scan-$(date +%Y%m%d-%H%M%S).pdf" >/dev/null 2>&1
  '';
  brscanSkey = pkgs.stdenv.mkDerivation {
    pname = "brscan-skey";
    version = "0.3.1-2";
    src = pkgs.fetchurl {
      url = "https://download.brother.com/pub/com/linux/linux/packages/brscan-skey-0.3.1-2.amd64.deb";
      hash = "sha256-ZsKPofdvgu0+c49VkrtlHw2YMyNj+3/Y23EsuMGJc4k=";
    };
    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook pkgs.makeWrapper ];
    buildInputs = [ pkgs.libusb1 pkgs.sane-backends (lib.getLib pkgs.stdenv.cc.cc) ];
    unpackPhase = "dpkg-deb -x $src .";
    installPhase = ''
      mkdir -p $out/opt/brother/scanner
      cp -r opt/brother/scanner/brscan-skey $out/opt/brother/scanner/
      chmod -R u+w $out/opt/brother/scanner/brscan-skey
      # Point every button function at our scan-to-PDF action.
      printf '%s\n' 'password=' \
        'IMAGE=${brscanSkeyAction}' 'OCR=${brscanSkeyAction}' \
        'EMAIL=${brscanSkeyAction}' 'FILE=${brscanSkeyAction}' 'SEMID=b' \
        > $out/opt/brother/scanner/brscan-skey/brscan-skey.config
    '';
    postFixup = ''
      wrapProgram $out/opt/brother/scanner/brscan-skey/brscan-skey-exe \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libusb1 ]}
    '';
  };

  # vimium-toggle: GLOBAL Vimium on/off, resting state OFF (opt-in "vim mode"),
  # bound to SUPER+SHIFT+V in dotfiles' hypr bindings.conf (plain SUPER+V is
  # omarchy's Universal paste). Chrome exposes no
  # enable/disable shortcut and Vimium's only command is its popup, so an
  # external toggle drives this). It flips Vimium's OWN mechanism: a `{pattern:"*", passKeys:""}`
  # global absolute-exclusion rule in chrome.storage.sync (Vimium is deny-list
  # only, so per-page opt-in over a default-off isn't expressible) — reached over
  # CDP (:9222) through a Vimium content-script isolated world (the MV3 service
  # worker is usually dormant, so we never rely on it). It nudges the focused tab
  # (found via Hyprland's active window — Chrome on Wayland doesn't report
  # document.hasFocus() reliably) with a no-op history.replaceState so the change
  # is live (no reload) via Vimium's onHistoryStateUpdated re-check path. Only one
  # tab is touched, so it's fast regardless of tab count. python3 +
  # websocket-client + libnotify pinned here so it never needs system packages.
  vimiumToggle = pkgs.writeShellApplication {
    name = "vimium-toggle";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: [ ps.websocket-client ]))
      pkgs.libnotify  # notify-send: visible ON/OFF feedback (toggle is otherwise silent)
    ];
    text = ''exec python3 ${./files/vimium-toggle.py} "$@"'';
  };

  # See the message the way the RECIPIENT will: headless Chromium screenshots
  # the HTML part, chafa paints the PNG inline in the terminal. The existing
  # text renderers cannot do this job — chawan and w3m confirm the words
  # survived and say nothing about whether the styling did, which is the only
  # thing worth reviewing about mail that was composed for you.
  #
  # chromium is deliberately NOT a runtimeInput: /usr/bin/chromium (the Omarchy
  # system browser, already the CDP target) is inherited from PATH, and pulling
  # a second nixpkgs chromium in would be ~400MB for a screenshot. imagemagick
  # crops the render (Chromium screenshots the WINDOW, not the page).
  # --text reuses aercChawanHtml verbatim, so an in-aerc preview is byte-for-byte
  # what the message view would show for the same part — no second renderer whose
  # output could disagree with the one you read mail in.
  mailPreview = pkgs.writeShellApplication {
    name = "mail-preview";
    runtimeInputs = [ pkgs.python3 pkgs.chafa pkgs.imagemagick pkgs.himalaya ];
    text = ''
      export CHA_HTML=${aercChawanHtml}
      exec python3 ${./files/mail-preview.py} "$@"
    '';
  };

  # Markdown is the ONLY hand-written form of a message body in this setup; HTML
  # is generated on the way out and destroyed on the way in. These two scripts
  # are that pair, and both are on PATH (not just referenced by store path)
  # because three unrelated callers need them: aerc's [multipart-converters],
  # aerc's reply/forward templates, and the nvim mail ftplugin.
  #
  # Plain gfm, NOT gfm-raw_html. `-raw_html` reads as "keep the Markdown clean",
  # but it is a silent-deletion switch: pandoc's gfm writer emits the literal
  # placeholder `[TABLE]` for any table it cannot express as a pipe table, and
  # with raw HTML disabled there is no fallback, so the content is dropped. A
  # 29KB table-layout message converted to 100 bytes reading `[TABLE]` and a
  # tracking pixel, and was forwarded that way. Raw-HTML passthrough is the
  # lesser evil: soup in the composer beats a body that isn't there.
  # For third-party HTML whose layout matters, don't convert at all — `:forward
  # -F` attaches the original as message/rfc822 (bound to F in binds.conf).
  #
  # $1 is a wrap width, and 0 (the default) means do not wrap: one paragraph
  # comes back as one line, matching the soft-wrap-only editor. The nvim
  # ftplugin passes its own textwidth, so the two agree by construction --
  # set textwidth there and the conversion follows it.
  #
  # Unwrapped output can exceed the 998-octet line limit of RFC 5322. That is
  # safe here only because aerc encodes the body quoted-printable, which soft-
  # breaks long lines on the wire.
  mailHtmlToMd = pkgs.writeShellApplication {
    name = "mail-html2md";
    runtimeInputs = [ pkgs.pandoc ];
    text = ''
      columns="''${1:-0}"
      if [ "$columns" -gt 0 ]; then
        exec pandoc -f html -t gfm --columns="$columns"
      fi
      exec pandoc -f html -t gfm --wrap=none
    '';
  };

  # Standalone documents, not fragments: Outlook and Gmail both accept a bare
  # fragment, but a <head> is the only place to put the CSS below, and mail
  # clients strip <style> far less often than they honour a stylesheet link.
  # The palette is GitHub's, chosen because the Markdown was written expecting
  # GitHub's rendering of it.
  #
  # --no-highlight: pandoc's syntax highlighter emits a <div class="sourceCode">
  # wrapper full of per-token <span>s and anchor links, which no mail client
  # styles and every mail client's quoting mangles. Plain <pre><code> survives.
  mailMdToHtmlTemplate = pkgs.writeText "mail-md2html.html" ''
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
    body{font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:#1f2328}
    blockquote{margin:0 0 0 .8em;padding:0 0 0 .8em;border-left:3px solid #d0d7de;color:#57606a}
    pre,code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
    pre{background:#f6f8fa;padding:.6em .8em;border-radius:6px;overflow-x:auto}
    code{background:#f6f8fa;padding:.1em .3em;border-radius:4px}
    pre code{background:none;padding:0}
    table{border-collapse:collapse}th,td{border:1px solid #d0d7de;padding:.3em .6em}
    img{max-width:100%}
    a{color:#0969da}
    </style>
    </head>
    <body>
    $body$
    </body>
    </html>
  '';

  mailMdToHtml = pkgs.writeShellApplication {
    name = "mail-md2html";
    runtimeInputs = [ pkgs.pandoc ];
    text = ''
      exec pandoc -f gfm -t html5 --standalone --no-highlight \
        --email-obfuscation=none --template=${mailMdToHtmlTemplate}
    '';
  };

  # Tab-completion for aerc's To/Cc/Bcc fields, ranked by frecency over mail you
  # have actually exchanged. aerc has no built-in address book at all: without an
  # address-book-cmd, <C-o> completes nothing, in compose AND in forward.
  aercAddressBook = pkgs.writeShellApplication {
    name = "aerc-addressbook";
    runtimeInputs = [ pkgs.himalaya pkgs.python3 ];
    text = ''exec python3 ${./files/aerc-addressbook.py} "$@"'';
  };

  # Morgen ships no usable icon, so pull the real one from the web app's
  # apple-touch-icon (a real 180px PNG).
  morgenIcon = pkgs.fetchurl {
    url = "https://web.morgen.so/apple-touch-icon.png";
    hash = "sha256-MiLXn1LrP/9idaof4t2fAAADyh3+qw9bdqMva2h7LPE=";
  };

  # Claude scheduled routines — the Linux equivalent of the macOS launchd agents
  # in dotfiles/Library/LaunchAgents (which never ran here: Linux has no launchd
  # and no ~/Library). Each is a systemd user timer+oneshot that invokes a
  # /<skill> slash command through the `claude` CLI's Remote Control (--rc --bg),
  # so no scheduled-tasks/ dir is needed — the skill bodies live in ~/.claude/
  # skills. Adapted from the plists: `claude` not `claude-stable`, $HOME not the
  # Mac path, vault at ~/notes not ~/Documents/Notes/Vault. Logs -> the journal
  # (journalctl --user -u claude-<name>). See ~/nix/CLAUDE.md.
  claudeRoutineEnv = [
    # systemd user services get a bare env — no shell rc, no home.sessionVariables.
    # Include the bun/pixi global-bin dirs (qmd etc.). BUN_INSTALL keeps bun's
    # global dir on-PATH despite XDG_CACHE_HOME (see dotfiles/.shell_path).
    #
    # No CDP_PORT: the CLIs discover their endpoint themselves (the Electron
    # desktop app's port, then Chrome/Chromium), so the routines' morgen calls
    # find the browser-wide :9222 without being told — and stay correct if a
    # desktop app ever lands on this host.
    "PATH=%h/.local/bin:%h/.bun/bin:%h/.pixi/bin:%h/.nix-profile/bin:/usr/bin:/bin"
    "CLAUDE_CONFIG_DIR=%h/.claude"
    "BUN_INSTALL=%h/.bun"
  ];
  # Spawn a Claude session into a Herdr tab, so the routines' agents show up in
  # the workspace list the user is actually looking at. `claude --bg` is invisible
  # to `herdr agent list` — that visibility is the whole point of this helper.
  # Keeps `-n "$LABEL"` so `agent-msg`/`claude agents` still resolve the session
  # by name (the wrapup + shutdown routines below depend on that).
  # usage: claude-herdr-spawn <dir> <tab-label> <agent-name> [prompt]
  claudeHerdrSpawn = pkgs.writeShellScript "claude-herdr-spawn" ''
    set -uo pipefail
    DIR="$1"; LABEL="$2"; AGENT_NAME="$3"; PROMPT="''${4:-}"
    cd "$DIR" || exit 1
    command -v herdr >/dev/null 2>&1 || { echo "no herdr on this host" >&2; exit 1; }

    # `herdr server` runs headless in the FOREGROUND — detach and poll for the
    # socket rather than racing it. A stopped server is startable, not a reason
    # to fall back to --bg.
    if ! herdr status server >/dev/null 2>&1; then
      setsid herdr server >/dev/null 2>&1 &
      for _ in $(seq 1 20); do
        herdr status server >/dev/null 2>&1 && break
        sleep 0.5
      done
      herdr status server >/dev/null 2>&1 || { echo "herdr server would not start" >&2; exit 1; }
    fi

    # Land the agent in the workspace that already belongs to $DIR, so a project's
    # agents stay together instead of accreting a new workspace every run (a daily
    # timer would otherwise leave one per day). `workspace list` carries no path,
    # so resolve through panes — `pane list` reports each pane's cwd — and fall
    # back to a label match. Never borrow the FOCUSED workspace: focus is wherever
    # the user happens to be standing and is unrelated to this spawn.
    WORKSPACE=$(herdr pane list 2>/dev/null \
      | jq -r --arg d "$DIR" '[.result.panes[] | select(.cwd == $d) | .workspace_id][0] // empty')
    if [ -z "''${WORKSPACE:-}" ]; then
      WORKSPACE=$(herdr workspace list 2>/dev/null \
        | jq -r --arg l "$(basename "$DIR")" \
            '[.result.workspaces[] | select(.label == $l) | .workspace_id][0] // empty')
    fi

    if [ -n "''${WORKSPACE:-}" ]; then
      CREATED=$(herdr tab create --workspace "$WORKSPACE" --cwd "$DIR" --label "$LABEL" --no-focus) || exit 1
      PANE=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.pane_id')
      TAB=$(printf '%s' "$CREATED" | jq -r '.result.tab.tab_id')
    else
      # Nothing for this project yet. `workspace create` already yields a root pane
      # at --cwd; calling `tab create` after it would strand an empty shell tab.
      WS=$(herdr workspace create --label "$(basename "$DIR")" --cwd "$DIR") || exit 1
      PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
      TAB=$(printf '%s' "$WS" | jq -r '.result.root_pane.tab_id')
      herdr tab rename "$TAB" "$LABEL" >/dev/null 2>&1 || true
    fi
    [ -n "''${PANE:-}" ] && [ "$PANE" != null ] || { echo "no pane for $DIR" >&2; exit 1; }

    # `agent start` launches + detects + waits for interactive readiness in ONE
    # call; pane run + agent wait races and returns agent_not_found.
    #
    # A freshly created workspace's root pane is not a live shell yet: starting
    # immediately fails with `agent_pane_busy: ... is not an available shell`
    # (reproduced 2026-08-13; the same call succeeded after ~3s). Retry rather
    # than sleeping a fixed amount, since the delay is load-dependent.
    STARTED=""
    for _ in $(seq 1 10); do
      if STARTED=$(herdr agent start "$AGENT_NAME" --kind claude --pane "$PANE" --timeout 60000 \
                     -- --rc --effort medium -n "$LABEL" 2>&1); then
        break
      fi
      case "$STARTED" in
        *agent_pane_busy*) sleep 1; STARTED="" ;;
        *) break ;;
      esac
    done
    if [ -z "''${STARTED:-}" ] || ! printf '%s' "$STARTED" | jq -e '.result.agent.interactive_ready == true' >/dev/null 2>&1; then
      herdr tab close "$TAB" >/dev/null 2>&1 || true
      echo "agent start failed: ''${STARTED:-pane never became an available shell}" >&2; exit 1
    fi

    if [ -n "$PROMPT" ]; then
      # Exit 0 without --wait only means "text written to the pane": Claude's TUI
      # collapses a big paste and intermittently eats the trailing Enter. Verify
      # with --until working. `timeout` means it DID submit and is still working;
      # only agent_prompt_stalled means it did not. Never close the tab on a stall.
      POUT=$(herdr agent prompt "$PANE" "$PROMPT" --wait --until working --timeout 15000 2>&1) || {
        case "$POUT" in
          *agent_prompt_stalled*)
            herdr pane send-keys "$PANE" enter >/dev/null 2>&1
            sleep 2
            echo "note: prompt stalled in the input box; sent enter" >&2 ;;
          *'"code":"timeout"'*) : ;;
          *) echo "prompt delivery failed: $POUT" >&2 ;;
        esac
      }
    fi
    echo "spawned '$LABEL' in herdr (pane=$PANE tab=$TAB)"
  '';
  claudeRoutines = {
    # Daily 08:00. Weekday: spawn the day's long-lived "🦞 assistant" session
    # with the briefing, then poke it for planning an hour later (same session,
    # so it inherits context). Weekend: spawn an idle session, no briefing.
    "claude-morning-briefing" = {
      desc = "Claude morning briefing — spawn the day's 🦞 assistant session";
      cwd = "%h/areas/assistant";
      onCalendar = "*-*-* 08:00:00";
      spawner = true;
      script = pkgs.writeShellScript "claude-morning-briefing" ''
        set -uo pipefail
        cd "$HOME/areas/assistant" || exit 1
        DOW=$(date +%u)  # 1=Mon … 7=Sun
        if [ "$DOW" -le 5 ]; then
          ${claudeHerdrSpawn} "$HOME/areas/assistant" "🦞 assistant" assistant "/morning-briefing" || true
          # Poke the SAME session for planning 1h later; detached so it survives
          # this oneshot exiting (KillMode=process keeps it out of the cgroup kill).
          nohup bash -c 'sleep 3600; agent-msg send --as-user "🦞 assistant" "/morning-planning"' >/dev/null 2>&1 &
        else
          ${claudeHerdrSpawn} "$HOME/areas/assistant" "🦞 assistant" assistant || true
        fi
      '';
    };
    # Mon–Fri 23:00. Route /nightly-wrapup into the live 🦞 assistant session so
    # it inherits the day's context; fall back to a standalone session if none.
    "claude-nightly-wrapup" = {
      desc = "Claude nightly wrapup — route into the day's 🦞 assistant session";
      cwd = "%h/areas/assistant";
      onCalendar = "Mon-Fri 23:00:00";
      spawner = true;
      script = pkgs.writeShellScript "claude-nightly-wrapup" ''
        set -uo pipefail
        cd "$HOME/areas/assistant" || exit 1
        # Resolve the day's 🦞 assistant to a cloud control-plane id (cse_…) that
        # `agent-msg send` accepts — the LOCAL section of `agent-msg list`.
        #
        # --as-user is REQUIRED, not cosmetic. A default (peer) send arrives
        # wrapped in "Another Claude session sent a message" framing with SLASH
        # COMMANDS DISABLED, so "/nightly-wrapup" lands as inert text and the
        # skill never loads; worse, a peer send can be held by crossSessionInbound
        # awaiting approval and never reach the model at all, while the sender
        # still sees exit 0. This is a self-send of a slash command into the
        # user's own session — exactly what --as-user is for.
        target=$(agent-msg list 2>/dev/null \
          | sed -n '/LOCAL/,/CLOUD/p' \
          | grep -F '🦞 assistant' \
          | grep -oE 'cse_[A-Za-z0-9]+' | head -1)
        if [ -n "''${target:-}" ] && agent-msg send --as-user "$target" "/nightly-wrapup"; then
          echo "wrapup routed into assistant session ($target)"
          exit 0
        fi
        echo "no live assistant session — spawning standalone wrapup"
        ${claudeHerdrSpawn} "$HOME/areas/assistant" nightly-wrapup nightly-wrapup "/nightly-wrapup"
      '';
    };
    # Daily 03:00, in the Obsidian vault (~/notes on Linux).
    "claude-vault-compile" = {
      desc = "Claude vault compile — nightly notes reindex";
      cwd = "%h/notes";
      onCalendar = "*-*-* 03:00:00";
      spawner = true;
      script = pkgs.writeShellScript "claude-vault-compile" ''
        set -euo pipefail
        cd "$HOME/notes" || exit 1
        ${claudeHerdrSpawn} "$HOME/notes" vault-compile vault-compile "/vault-compile"
      '';
    };
    # Daily 03:30 — headless BACKSTOP snapshot of the vault's LOCAL-ONLY git repo
    # (no remote by design: consulting work product stays off third-party hosts).
    # Primary autosave is the Obsidian Git plugin (30-min commit-and-sync, push
    # disabled), but that only runs while Obsidian is open — this catches stretches
    # where it's closed while the 03:00 compile and other skills rewrite notes.
    # Runs after the compile so it sweeps up whatever that step didn't commit.
    # Plain script, no Claude session, so spawner = false.
    "vault-autocommit" = {
      desc = "Vault autocommit — daily backstop snapshot of ~/notes";
      cwd = "%h/notes";
      onCalendar = "*-*-* 03:30:00";
      spawner = false;
      script = pkgs.writeShellScript "vault-autocommit" ''
        set -uo pipefail
        cd "$HOME/notes" || exit 0
        # No-op on a host where the vault isn't a repo (Mac: Obsidian Sync only).
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
          echo "not a git repo — nothing to do"; exit 0; }
        git add -A
        if git diff --cached --quiet; then
          echo "no changes"
          exit 0
        fi
        git commit -qm "vault: backstop autosave $(date '+%Y-%m-%d %H:%M')"
        git --no-pager diff --shortstat HEAD~1 HEAD
      '';
    };
    # Daily 02:45 — cleanly stop the day's 🦞 assistant before the 03:00 vault
    # compile. Deliberate stop (not a crash), so it is not auto-respawned.
    "claude-assistant-shutdown" = {
      desc = "Claude assistant shutdown — stop the day's 🦞 assistant session";
      cwd = "%h/areas/assistant";
      onCalendar = "*-*-* 02:45:00";
      spawner = false;
      script = pkgs.writeShellScript "claude-assistant-shutdown" ''
        set -uo pipefail
        stopped=0
        # Herdr-hosted routines (the normal case since the --bg -> herdr move):
        # closing the tab ends the foreground `claude --rc` that owns the pane.
        if command -v herdr >/dev/null 2>&1 && herdr status server >/dev/null 2>&1; then
          tabs=$(herdr agent list 2>/dev/null | jq -r '
            .result.agents[]
            | select(.terminal_title_stripped
                     | test("🦞 assistant|morning-briefing|nightly-wrapup"))
            | .tab_id')
          for t in ''${tabs:-}; do
            if herdr tab close "$t" >/dev/null 2>&1; then
              echo "closed herdr tab $t"; stopped=$((stopped + 1))
            else
              echo "FAILED to close herdr tab $t"
            fi
          done
        fi
        # Any lingering daemon sessions (adopted, or spawned before the move).
        ids=$(claude agents --json 2>/dev/null \
          | jq -r '.[] | select(.name == "🦞 assistant" or .name == "morning-briefing" or .name == "nightly-wrapup") | .id')
        for id in ''${ids:-}; do
          [ "$id" = null ] && continue
          if claude stop "$id"; then echo "stopped $id"; stopped=$((stopped + 1)); else echo "FAILED to stop $id"; fi
        done
        [ "$stopped" -gt 0 ] || echo "nothing to stop"
      '';
    };
  };
  mkRoutineService = r: {
    Unit.Description = r.desc;
    Service = {
      Type = "oneshot";
      WorkingDirectory = r.cwd;
      Environment = claudeRoutineEnv;
      ExecStart = "${r.script}";
    } // lib.optionalAttrs r.spawner {
      # Leave the backgrounded `claude --rc --bg` session (and the planning poke)
      # running after the oneshot exits — the launchd equivalent of the plist's
      # AbandonProcessGroup=true.
      KillMode = "process";
    };
  };
  mkRoutineTimer = r: {
    Unit.Description = "${r.desc} (timer)";
    # Persistent=false: don't fire a stale routine on a late boot/wake — a
    # briefing that missed 08:00 shouldn't spawn at noon.
    Timer = { OnCalendar = r.onCalendar; Persistent = false; };
    Install.WantedBy = [ "timers.target" ];
  };

in
{
  imports = [
    ../../../modules/shared/home-secrets.nix
    # chrome-cdp + readwise-reader-tools services. Cross-platform module: emits
    # systemd user services + a timer here (Linux) and launchd agents on macOS.
    ../../../modules/shared/reader-services.nix
    # Faithful docx->PDF via real Word in a QEMU Win11 x64 + KVM guest; also a
    # host for Windows-only tools (e.g. BenQ Display QuicKit). Enabled below.
    ../../../modules/shared/word-render.nix
    # herdr's agent skill, sourced from the same flake input as the binary so the
    # doc can never describe a different version than the CLI it documents.
    ../../../modules/shared/herdr-skill.nix
  ];

  # Ships qemu + swtpm + xorriso + the VM provisioning kit (word-render-provision,
  # start-winvm.sh, ...). See modules/shared/word-render/README.md. (2026-07-11)
  programs.wordRender.enable = true;

  # This computer is the always-on primary: it runs BOTH the chrome-cdp browser
  # and the readwise webhook + sweep (the tunnel points here). See
  # modules/shared/reader-services.nix.
  readerServices = {
    enableChromeCdp = true;
    enableReadwise = true;
    enablePaperpile = true;
  };

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";

    # Cherry-picked packages not in Omarchy/pacman
    packages = (import ../../../modules/linux/omarchy-packages.nix { inherit pkgs; })
      # Brother DS-740D scanner: patched brscan5 + wrapped scanimage (`brscan`).
      # See the `brscan5Patched`/`brscan` let-bindings above. Three root-owned
      # deps home-manager (foreign distro, no NixOS hardware.sane module) can't
      # place — install once, like the chromium managed policy below:
      #
      #   # 1. USB access rule (grant the seat user the scanner node):
      #   sudo install -Dm644 \
      #     ~/nix/hosts/linux/omarchy/files/60-brother-ds740d.rules \
      #     /etc/udev/rules.d/60-brother-ds740d.rules
      #
      #   # 2. brother5 backend reads model tables from these hard-coded paths;
      #   #    point them at the patched store config (via the home symlink below):
      #   sudo mkdir -p /etc/opt/brother/scanner
      #   sudo ln -sfn ~/.local/state/brother/brscan5 /etc/opt/brother/scanner/brscan5
      #   sudo ln -sfn ~/.local/state/brother/brscan5/models /etc/opt/brother/scanner/models
      #
      #   # 3. Force the scanner's port to USB 2.0 (unstable at SuperSpeed) —
      #   #    event-driven udev rules that survive sleeps/drops/replugs:
      #   sudo install -Dm644 \
      #     ~/nix/hosts/linux/omarchy/files/99-ds740d-force-usb2.rules \
      #     /etc/udev/rules.d/99-ds740d-force-usb2.rules
      #   sudo udevadm control --reload && sudo udevadm trigger
      #
      #   # 4. Button watcher: the brscan-skey daemon hard-codes its /opt path.
      #   #    Symlink it to the store copy (the brscan-skey user service runs it):
      #   sudo mkdir -p /opt/brother/scanner
      #   sudo ln -sfn ~/.local/state/brother/brscan-skey /opt/brother/scanner/brscan-skey
      #   # Press the scanner's Start button → duplex scan lands in ~/scans/*.pdf.
      #
      # Scanning front-ends:
      #   brscan-tui   # interactive gum TUI (mode/dpi/sides/format incl. PDF → scan)
      #   brscan …     # raw scanimage (e.g. `brscan -L`, `--format=png -o x.png`)
      # (brscanPdf is the TUI's internal PDF engine — see runtimeInputs, not on PATH.)
      # ghostty: the default terminal here (see xdg-terminals.list below). Comes
      # from the Linux overlay's nixGLIntel-wrapped override, not pacman — the
      # wrapper is also where GDK_SCALE gets unset, which the distro build would
      # need a hand-maintained desktop-entry override to do.
      # sunshine: Moonlight streaming host (see the sunshine user service and
      # xdg.configFile."sunshine/sunshine.conf" below). nixGLIntel-wrapped in
      # the Linux overlay — the stock binary can't reach Mesa on non-NixOS.
      # Only listed for this host: `alarm` shares omarchy-packages.nix but is
      # a headless aarch64 box with nothing to stream.
      ++ [
        brscan brscanTui vimiumToggle mailPreview aercAddressBook telGvoice
        mailHtmlToMd mailMdToHtml
        pkgs.ghostty pkgs.sunshine
      ];

    # host-dispatch agent dir (ensure.sh + system-prompt.md) lives in dotfiles
    # but ~/.claude is not stow-managed here, so link it in out-of-store (live-
    # editable, matches the macOS ~/.claude/agents/host-dispatch layout that
    # ensure.sh's AGENT_DIR/PROMPT_FILE expect). Consumed by the host-dispatch
    # systemd service above.
    file.".claude/agents/host-dispatch".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/.claude/agents/host-dispatch";

    # Install the AI CLIs idempotently on every build-switch, as mise stubs in
    # ~/.local/bin (mirrors the macOS installAITools). Same mechanism as
    # Omarchy's own install/user/mise.sh, so the two agree on any tool they
    # both name; this one additionally covers agy/qmd/readwise, which Omarchy
    # doesn't install. setup-ai-tools.sh lives in this flake, hence ${self}.
    activation.installAITools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD env \
        PATH="$HOME/.local/bin:$HOME/.bun/bin:${pkgs.mise}/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
        AI_TOOLS_SKIP="${lib.concatStringsSep " " (userInfo.aiToolsSkip or [])}" \
        ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh || true
    '';

    # Then link the dotfiles-tracked ~/.claude children (CLAUDE.md, settings.json,
    # hooks/, skills/, commands, …). `stow .` skips ~/.claude (it holds runtime
    # state — sessions/, plugins/cache/, credentials), so this bootstrap is what
    # deploys them; nothing ran it before, which is how the hooks/ link went
    # missing. Ordered AFTER installAITools so Claude Code is present first.
    # Idempotent and refuses to clobber real files. Script lives in dotfiles,
    # so reference it under $HOME/dotfiles (not ${self}).
    activation.setupClaudeSymlinks = lib.hm.dag.entryAfter [ "installAITools" ] ''
      $DRY_RUN_CMD env PATH="${pkgs.coreutils}/bin:/usr/bin:/bin" \
        ${pkgs.bash}/bin/bash "$HOME/dotfiles/scripts/setup-claude-symlinks.sh" || true
    '';

    # tel: -> Google Voice (see the google-voice desktop entry). mimeapps.list is
    # a plain file here, so this rewrites only this one association and leaves the
    # rest of the user's imperative choices alone. Idempotent.
    activation.telHandler = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${pkgs.xdg-utils}/bin/xdg-mime default google-voice.desktop \
        x-scheme-handler/tel || true
    '';

    # swlinux dictation models (large, non-store) — fetch once to
    # ~/.local/share/swlinux/models. Parakeet v3 STT + the open Qwen2.5-1.5B
    # cleanup fallback. The tuned cleanup model (s1-mini.gguf, private) is placed
    # out-of-band and pointed at by the daemon's SWLINUX_LOCAL_MODEL below.
    activation.swlinuxModels = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      MODELS="$HOME/.local/share/swlinux/models"
      $DRY_RUN_CMD mkdir -p "$MODELS"
      if [ ! -d "$MODELS/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8" ]; then
        $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fL --retry 3 -o "$MODELS/p.tar.bz2" \
          https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2 \
          && $DRY_RUN_CMD ${pkgs.gnutar}/bin/tar -xjf "$MODELS/p.tar.bz2" -C "$MODELS" \
          && $DRY_RUN_CMD rm -f "$MODELS/p.tar.bz2"
      fi
      if [ ! -f "$MODELS/qwen2.5-1.5b-instruct-q4.gguf" ]; then
        $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fL --retry 3 -o "$MODELS/qwen2.5-1.5b-instruct-q4.gguf" \
          https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf
      fi
    '';

    # Patched brscan5 model tables at a stable home path; /etc/opt/brother is
    # symlinked here by the one-time sudo step (see home.packages above). Stable
    # across brscan5 updates — the symlink target (home path) never changes.
    file.".local/state/brother/brscan5".source =
      "${brscan5Patched}/opt/brother/scanner/brscan5";

    # brscan-skey daemon + baked config at a stable home path; the binary
    # hard-codes /opt/brother/scanner/brscan-skey, symlinked here by the one-time
    # root step (see home.packages). Run by the brscan-skey user service below.
    file.".local/state/brother/brscan-skey".source =
      "${brscanSkey}/opt/brother/scanner/brscan-skey";

    # Scanner launcher entry, written to ~/.local/share/applications
    # (XDG_DATA_HOME) rather than via xdg.desktopEntries, so the Exec below can
    # name the wrapper script directly. TUI.float →
    # Hyprland floats the terminal (see files/.../system.conf). `scanner` is a
    # Papirus icon name.
    # HTML signatures, concatenated into the HTML body by the compose pipeline
    # in the email-handling skill. They have no upstream home: mml's `signature`
    # key is plain text with an RFC 3676 sig-dash, and the work signature is an
    # HTML <div> whose orange Web | SSRN | Bio anchors cannot survive that. So
    # they stay files, and the mml config below deliberately sets no `signature`
    # — otherwise every message would carry a plain-text one as well.
    # The work one was recovered verbatim from sent mail; do not paraphrase it.
    file.".local/share/himalaya/signatures/work.html".source =
      ./files/himalaya-signature-work.html;
    file.".local/share/himalaya/signatures/personal.html".source =
      ./files/himalaya-signature-personal.html;

    file.".local/share/applications/scanner.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Scanner (DS-740D)
      Comment=Brother DS-740D document scanner
      Exec=xdg-terminal-exec --app-id=TUI.float -e ${brscanTui}/bin/brscan-tui
      Icon=scanner
      Terminal=false
      Categories=Utility;
      StartupNotify=true
    '';

    # Obsidian launcher override. MUST live here under ~/.local/share/applications
    # (XDG_DATA_HOME), NOT via xdg.desktopEntries: if the Arch obsidian package is
    # ever present it ships /usr/share/applications/obsidian.desktop, and on this
    # host /usr/share precedes the nix-profile share in XDG_DATA_DIRS — so a
    # profile entry loses. XDG_DATA_HOME wins over both.
    #
    # Exec is the nix-managed, nixGL-wrapped `obsidian` (flake overlay), NOT the
    # Arch `/usr/bin/obsidian`: the distro's electron39 blocks Obsidian's `app://`
    # PDF fetch with a CORS error, so in-app PDF preview renders blank. nixpkgs'
    # electron renders PDFs correctly. See the flake overlay comment for the full
    # diagnosis. (After switching, remove the pacman package: `sudo pacman -Rns
    # obsidian` — otherwise its /usr/bin/obsidian and /usr/share desktop entry
    # linger; harmless but stale.)
    #
    # --ozone-platform=wayland + --enable-wayland-ime keep NATIVE Wayland (the
    # nixpkgs wrapper only adds these when NIXOS_OZONE_WL is set, which this host
    # does not export), so GDK_SCALE=2 coords stay consistent with the hints
    # "obsidian" scale_factor=0.5 rule. --force-renderer-accessibility makes the
    # Electron renderer publish its web-content AT-SPI tree; without it `hints`
    # sees only the top-level frame (2 nodes) and can't hint anything (the
    # org.a11y toolkit-accessibility toggle alone is not enough for this Electron
    # build).
    file.".local/share/applications/obsidian.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Obsidian
      Comment=Obsidian
      Exec=obsidian --ozone-platform=wayland --enable-wayland-ime --force-renderer-accessibility %U
      Icon=obsidian
      Terminal=false
      Categories=Office;
      MimeType=x-scheme-handler/obsidian;
      StartupWMClass=obsidian
    '';

    # Icon theme symlinks (Papirus installed via home-manager, needs symlinks)
    file.".local/share/icons/Papirus".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus";
    file.".local/share/icons/Papirus-Dark".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark";

    # Install desktop entry icons
    file.".local/share/applications/icons/OpenCode.svg".source = "${iconDir}/OpenCode.svg";
    file.".local/share/applications/icons/Docker.svg".source = "${iconDir}/Docker.svg";
    file.".local/share/applications/icons/Tailscale.svg".source = "${iconDir}/Tailscale.svg";
    file.".local/share/applications/icons/Tailscale Admin Console.png".source = "${iconDir}/Tailscale Admin Console.png";
    file.".local/share/applications/icons/YouTube Music.png".source = "${iconDir}/YouTube Music.png";
    file.".local/share/applications/icons/Readwise Reader.png".source = "${iconDir}/Readwise Reader.png";
    file.".local/share/applications/icons/Calculator.svg".source = "${iconDir}/Calculator.svg";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts
  fonts.fontconfig.enable = true;

  # Enable home-manager
  programs.home-manager.enable = true;

  # No CDP_PORT on purpose. Both CLIs now discover their endpoint themselves —
  # the Electron desktop app's port first, then Chrome/Chromium — so pinning the
  # browser-wide :9222 globally is unnecessary here, and would be actively wrong
  # on a machine that has the desktop apps: an explicit CDP_PORT pins the
  # candidate list to one port, so the Electron probe never runs.
  #
  # Was: home.sessionVariables.CDP_PORT = "9222", whose own comment named the
  # bug — "morgen-cli defaults to 9253" — it was working around. Fixed properly
  # in morgen-cli v0.10.2.
  #
  # Per-invocation overrides remain: CDP_PORT pins one port and skips probing;
  # ELECTRON_CDP_PORT and CHROME_CDP_PORT move the candidates.

  # ydotool client -> ydotoold socket. The ydotoold user service (below) creates
  # the socket at %t/.ydotool_socket (= $XDG_RUNTIME_DIR); point the client at it
  # so `ydotool` works from any shell without a per-invocation --socket-path.
  # Enables the native Wayland "computer use" loop (grim = see, hyprctl + ydotool
  # = act) documented in the linux-computer-use skill.
  home.sessionVariables.YDOTOOL_SOCKET = "\${XDG_RUNTIME_DIR}/.ydotool_socket";

  # hints (keyboard-driven GUI navigation). Config, accessibility toggle and the
  # hintsd daemon service mirror hosts/linux/alarm — see there for the rationale
  # behind the role/state allow-lists. hintsd needs the user in the `input` group
  # (host/OS config, not managed here).
  xdg.configFile."hints/config.json".text = builtins.toJSON {
    hints = {
      hint_height = 22;
      hint_font_size = 11;
      hint_font_face = "Sans";
      hint_upercase = true;
      hint_background_r = 1.0;
      hint_background_g = 0.86;
      hint_background_b = 0.24;
      hint_background_a = 0.95;
      hint_font_r = 0.18;
      hint_font_g = 0.13;
      hint_font_b = 0.02;
      hint_font_a = 1.0;
      hint_pressed_font_r = 0.72;
      hint_pressed_font_g = 0.6;
      hint_pressed_font_b = 0.25;
      hint_pressed_font_a = 1.0;
    };
    backends = {
      enable = [ "atspi" ];
      atspi.application_rules = {
        default = {
          # scale_factor converts AT-SPI element coords -> Hyprland LOGICAL
          # coords (hints adds them to `hyprctl activewindow` .at, which is
          # logical). The right factor depends on the coord space the toolkit
          # reports, which is set by the app's env, not hintsd's.
          #
          # On this host GDK_SCALE=2 is exported to every app (monitors.conf
          # `env = GDK_SCALE,2`), so GTK3/GTK4/Chromium apps report AT-SPI
          # extents already in LOGICAL pixels (measured: waybar/stremio report a
          # 1920-wide window on the 3840px 2x panel, matching hyprctl's logical
          # 1920). They therefore need scale_factor = 1. With the upstream/alarm
          # default of 0.5 these coords get halved, so every hint drifts toward
          # the top-left by half its in-window offset — the misalignment Edwin
          # saw. Hence default = 1 here.
          #
          # (alarm keeps default 0.5 because the apps hit there are Qt, which
          # reports PHYSICAL 2x extents needing the halving; its GTK apps carry
          # explicit scale_factor=1 overrides. Same code, different app/toolkit
          # mix. If a PHYSICAL-reporting Qt app ever needs hinting here, give it
          # a per-class `scale_factor = 0.5` override — the inverse of alarm.)
          scale_factor = 1;
          # Allow-list only genuinely-interactive roles (roles_match_type 2 =
          # Atspi.CollectionMatchType.ANY). Atspi.Role int values:
          #   43 push button   88 link          79 entry        7 check box
          #   44 radio button  11 combo box     62 toggle btn  35 menu item
          #    8 check menuitem 45 radio menuitem 37 page tab   32 list item
          #   51 slider        52 spin button
          roles_match_type = 2;
          roles = [ 43 88 79 7 44 11 62 35 8 45 37 32 51 52 ];
        };
        # These GTK apps report LOGICAL coords like everything else here, so
        # scale_factor=1 now just matches the default. Kept explicit for parity
        # with alarm (where they override alarm's 0.5 default).
        "doublecmd".scale_factor = 1;
        "org.gnome.Nautilus".scale_factor = 1;
        # Obsidian (Electron): unlike this host's GTK apps, Chromium WEB CONTENT
        # reports PHYSICAL 2x AT-SPI extents even with GDK_SCALE=2 (measured:
        # links at window-relative x up to ~2100 in a 1258-logical-wide window;
        # sizes/gaps exactly 2x). So it needs the halving that alarm's default
        # applies globally — the "PHYSICAL-reporting app" case the default-rule
        # comment above anticipated. Keyed on the Hyprland window class
        # ("obsidian"); roles inherit from default. Requires the app to publish
        # its a11y tree at all, which the obsidian desktop entry forces via
        # --force-renderer-accessibility (the org.a11y toggle alone is not
        # enough for this Electron build).
        #
        # States: the default gate (SENSITIVE 24 + SHOWING 25) tags ALL rendered
        # markdown — every in-content link and task line — so a normal note
        # produces dozens of hints. Add FOCUSABLE (11) so only genuinely tabbable
        # targets hint: real nav links, file-tree items, ribbon buttons, tab
        # headers, task checkboxes; non-focusable content spans / list bullets
        # drop out. Measured on a task-heavy note: 36 -> 15 hints. Same
        # SENSITIVE+SHOWING+FOCUSABLE / match-ALL pattern as Beeper and Stremio.
        "obsidian" = {
          scale_factor = 0.5;
          states = [ 24 25 11 ];
          states_match_type = 1;
        };
        # Beeper: hint only conversation threads (FOCUSABLE `section` role 85)
        # plus the composer (entry role 79); require FOCUSABLE (11) + SENSITIVE
        # (24) + SHOWING (25), states_match_type 1 = ALL. See alarm for details.
        "BeeperTexts" = {
          roles = [ 85 79 ];
          roles_match_type = 2;
          states = [ 24 25 11 ];
          states_match_type = 1;
        };
        # Stremio: web UI in a GTK4/WebKit shell. Its controls (back button,
        # nav, player controls, cards) are non-semantic focusable `section`
        # divs (role 85, empty accessible name), so the default allow-list
        # skips them — only its genre/cast links (88), search box (79) and one
        # real button (43) were hinted. Add 85 and gate on FOCUSABLE (11) +
        # SENSITIVE (24) + SHOWING (25), states_match_type 1 = ALL, so only the
        # tabbable controls tag, not every layout div. Same pattern as Beeper;
        # re-list 88/79/43 because roles replaces (not extends) the default.
        # scale_factor inherits 1 from default (measured logical coords). Keyed
        # on the Hyprland window class (hyprctl activewindow .class).
        "com.stremio.Stremio" = {
          roles = [ 85 88 79 43 ];
          roles_match_type = 2;
          states = [ 24 25 11 ];
          states_match_type = 1;
        };
      };
    };
  };

  # Global accessibility toggle. Chromium/Electron/Qt apps only publish their
  # AT-SPI accessibility tree when assistive tech is marked active on the a11y
  # bus (org.a11y.Status.IsEnabled). Without this, `hints` gets no real elements
  # for those apps and falls back to opencv edge-detection (misaligned dupes).
  dconf.settings = {
    "org/gnome/desktop/interface".toolkit-accessibility = true;
  };

  # Chromium flags (Arch's chromium wrapper appends every line to each launch).
  # Reproduces the Omarchy defaults and adds browser-wide CDP: the main Default
  # profile (already logged in) owns the debug endpoint on :9222, and every
  # app window (Morgen, etc. launched via omarchy-launch-webapp) is a page on
  # that one endpoint — so morgen-cli, which probes here after finding no
  # Electron app, reads tokens from the live
  # session (this host has no desktop apps, so Chromium is the only route), no per-app
  # profile or manual re-login. force = it seeds a real file at install time.
  #
  # REQUIRES a managed policy: Chromium 136+ silently IGNORES
  # --remote-debugging-port on the *default* profile (anti-cookie-theft
  # mitigation), so the browser-wide CDP above is dead without it — :9222 never
  # opens. Re-enable it with a root-owned system policy (one-time; outside
  # home-manager's /etc scope, so not declarative here):
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-managed-policy.json \
  #     /etc/chromium/policies/managed/enable-remote-debugging.json
  # (RemoteDebuggingAllowed=true). Verify: curl -s localhost:9222/json/version.
  # SECURITY: this leaves a CDP port open on localhost whenever Chromium runs;
  # any local process can drive the browser. Acceptable on a personal machine;
  # scoped to this host only (not in shared dotfiles).
  #
  # Extensions are ALSO force-installed via a root-owned managed policy (same
  # /etc scope, so not declarative here) — Chromium sync is off, so this is the
  # only way the profile's extensions come back on a fresh machine. They
  # auto-install + auto-update from the Web Store and can't be removed by hand
  # while the policy is present. IDs = 1Password, Paperpile, Vimium, Tampermonkey,
  # Readwise, AdGuard, Perma.cc, Claude (copy-url is separate — loaded unpacked
  # via --load-extension below):
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-extensions-policy.json \
  #     /etc/chromium/policies/managed/extensions.json
  # Verify: chrome://policy (Reload policies) shows ExtensionInstallForcelist.
  #
  # Tampermonkey userscripts are PROVISIONED declaratively — a FOURTH policy.
  # Tampermonkey ships storage.managed_schema (schema.json in its bundle) with a
  # single key, `jsonImport`: a list of {url, hash} pointing at a Tampermonkey
  # JSON export. On startup it fetches each url, verifies the hash, installs the
  # scripts, and records the hash so it only ever applies once. That closes the
  # last manual step — a fresh machine ends up with the userscripts already
  # installed, no clicking through Tampermonkey's install page:
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-tampermonkey-policy.json \
  #     /etc/chromium/policies/managed/tampermonkey.json
  #
  # `source` MUST be BASE64 of the script's UTF-8 bytes, not raw text. The
  # installer does `Qe(Xe(source))` = decodeURIComponent(escape(atob(source))),
  # and that atob sits OUTSIDE its try/catch. Raw text throws
  # InvalidCharacterError (immediately, if the script contains any character
  # above U+00FF -- an em-dash in a @name is enough), the rejection escapes the
  # extension's init IIFE uncaught, and provisioning dies in total silence after
  # the "start downloading" line: no error, no scripts, no success marker, and a
  # half-initialised extension. Cost most of an evening and three independent
  # investigations to find; the first two theories (offscreen/XHR transport, then
  # a stuck request) were both wrong.
  #
  # The hash is NOT a plain sha256 of the file. Tampermonkey walks the parsed
  # JSON and hashes recursively: leaves as sha256("<typeof>:<value>"), arrays and
  # objects as sha256 of their children's hashes concatenated, object keys sorted
  # and the keys themselves NOT hashed. Prefix "1:" is the format version. So
  # reformatting the JSON is fine, but changing any value means recomputing.
  # Regenerate with scripts/tampermonkey-provisioning-hash.py.
  #
  # The bundle is only for FIRST install. Each script carries @updateURL pointing
  # at its own gist, so it self-updates afterwards and the bundle can go stale
  # without harm — it is a seed, not a sync channel.

  # Force-installing extensions has a NON-OBVIOUS side effect that needs a THIRD
  # policy. DeveloperToolsAvailability defaults to
  # DisallowedForForceInstalledExtensions, so the moment an extension arrives via
  # the forcelist above, ALL CDP attach to that extension's service worker is
  # refused — including our own tooling. Concretely: readwise-reader-tools could
  # still *find* the Readwise extension SW target but every message round-trip
  # timed out ("Timeout communicating with extension service worker"), 14/14
  # saves silently falling back to the weaker manual-extraction path. It broke on
  # 2026-07-15, the day the Readwise ID was added to the forcelist, and looked
  # exactly like the extension auth drift we'd seen before — hence the long
  # misdiagnosis. Root cause + probe: readwise-reader-tools
  # docs/investigations/2026-07-21_extension-save-blocked-by-forcelist-policy.md
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-devtools-policy.json \
  #     /etc/chromium/policies/managed/devtools-availability.json
  # Then: systemctl --user restart chrome-cdp
  # Verify: chrome://policy shows DeveloperToolsAvailability=1 (Allowed for all),
  # and CDP can attach to a force-installed extension's SW target.
  # NOTE the ordering dependency — adding ANY new extension to the forcelist
  # without this policy present re-breaks CDP access to it.
  xdg.configFile."chromium-flags.conf" = {
    force = true;
    text = ''
      --ozone-platform=wayland
      --ozone-platform-hint=wayland
      --enable-features=TouchpadOverscrollHistoryNavigation
      # ABSOLUTE PATHS, NOT ~. The Arch chromium wrapper is a C binary that
      # splits this file with g_shell_parse_argv ("shell quoting rules apply but
      # no further parsing is performed" -- its own --help). That does NOT expand
      # tilde, so `--load-extension=~/...` reaches Chromium with a literal ~ and
      # silently loads nothing. copy-url had been specified that way since it was
      # added and had NEVER loaded: the Default profile's extension list showed no
      # location=4 (command-line) entry at all, only the forcelist ones. Nothing
      # errors -- the flag is simply ignored -- which is why it went unnoticed.
      #
      # If a second unpacked extension is ever added here it MUST be appended
      # comma-separated to this same flag -- Chromium honours only the LAST
      # --load-extension, so a second line would silently drop copy-url.
      #
      # Paths are /usr/share/omarchy, NOT ~/.local/share/omarchy. Quattro made
      # /usr/share/omarchy canonical and ~/.local/share/omarchy a symlink to it.
      # Both resolve, but omarchy-upgrade-to-quattro's
      # repair_chromium_copy_url_extension_flags rewrites the legacy spelling to
      # the canonical one -- and since this file is a read-only /nix/store
      # symlink, that write dies with PermissionError and aborts the entire user
      # transition. It is guarded by a grep for the legacy path, so emitting the
      # canonical path makes the upgrade skip this file untouched.
      #
      # yt-dlp and whatsapp-slim are declared for the same reason: migrations
      # 1780517689 and 1785543725 otherwise `sed -i --follow-symlinks` them in
      # and fail the migration queue. Each greps its own extensions/ path first,
      # so declaring them here makes those migrations no-ops. Any FUTURE Omarchy
      # migration that edits this file needs the same treatment.
      --load-extension=/usr/share/omarchy/default/chromium/extensions/copy-url,/usr/share/omarchy/default/chromium/extensions/yt-dlp,/usr/share/omarchy/default/chromium/extensions/whatsapp-slim
      # Google account sign-in. Arch's chromium ships without Google's OAuth
      # credentials, so signing in silently does nothing; these are the ones
      # omarchy-install-chromium-google-account appends. That script writes with
      # a bare `>>` and has no `set -e`, so against this read-only /nix/store
      # symlink it fails with "Permission denied" and STILL prints "Now you can
      # login" -- declaring the flags here is the only thing that actually works.
      # It guards each line with `grep -qxF`, so these exact strings make it a
      # no-op. Keep them byte-identical to the script's if it ever changes them.
      --oauth2-client-id=77185425430.apps.googleusercontent.com
      --oauth2-client-secret=OTJgUOQcT7lO7GsGZq2G4IlT
      # Pin the os_crypt backend (Omarchy migration 1784508556). On Hyprland the
      # xdg-desktop-portal Secret backend has no provider, so Chromium can fall
      # back to the 'basic' v10 store; that makes cookies and passwords encrypted
      # under the gnome-libsecret v11 key undecryptable and silently logs you out
      # of everything.
      --password-store=gnome-libsecret
      --remote-debugging-port=9222
      --remote-allow-origins=*
      # Keep the visible-but-unfocused browser window's ACTIVE tab reachable. In
      # a tiling WM the browser is often visible but not the focused window;
      # Chromium's occlusion detection then treats it as occluded and freezes its
      # active tab after ~5s, and a frozen tab rejects new CDP connections — so
      # vimium-toggle (Hyper+V) can't reach the tab you're looking at until you
      # refocus. This single flag stops that occlusion-backgrounding while leaving
      # genuinely-hidden background tabs free to freeze AND discard normally, so
      # CPU/battery + RAM savings are preserved for tabs you're not looking at.
      --disable-backgrounding-occluded-windows
    '';
  };


  # Machine-specific Hyprland/audio config, managed here (not shared dotfiles)
  # because it's tied to THIS box's hardware — the DCN31 GPU + BenQ display and
  # the ALC623 audio codec — and would be wrong on the alarm host. force = true
  # overrides the Omarchy-seeded defaults. See each file for the rationale.
  #   - hypridle.conf: never dpms-off the panel (DCN31 dp_blank wedge workaround)
  #   - monitors.conf: DP-4 @ preferred(144), scale 2
  #   - 50-prefer-hdmi.conf: disable onboard analog out, prefer HDMI/DP audio
  xdg.configFile."hypr/hypridle.conf" = { source = ./files/hypridle.conf; force = true; };
  xdg.configFile."hypr/monitors.conf" = { source = ./files/monitors.conf; force = true; };
  xdg.configFile."wireplumber/wireplumber.conf.d/50-prefer-hdmi.conf" = {
    source = ./files/wireplumber-prefer-hdmi.conf;
    force = true;
  };

  # Autostart the CDP web apps on login (Hyprland sources this user autostart
  # slot; Omarchy's own defaults live in a separate file). Guarantees Morgen —
  # and thus the browser-wide :9222 endpoint morgen-cli attaches to — is up for
  # the 08:00 scheduled briefing even after a reboot.
  # launch-or-focus (not launch) won't duplicate the windows you keep open all day.
  xdg.configFile."hypr/autostart.conf" = {
    force = true;
    text = ''
      exec-once = omarchy-launch-or-focus-webapp morgen https://web.morgen.so
    '';
  };

  # Host-local ghostty override (included last by the shared ~/.config/ghostty/
  # config). The shared font-size 14 is tuned for macOS Retina and renders too
  # big on this 32" 4K @ scale-2 panel, so shrink it here only — macOS/alarm keep their own size.
  xdg.configFile."ghostty/local.conf".text = "font-size = 10\n";

  # Sunshine (Moonlight streaming host). Two settings here are load-bearing on
  # Hyprland; both were found the hard way, so do not "simplify" them away:
  #
  #   capture = wlr
  #     MANDATORY. Left on auto, Sunshine probes the xdg-desktop-portal
  #     RemoteDesktop interface first. xdg-desktop-portal-hyprland (1.4.0 here)
  #     does not implement RemoteDesktop, and instead of failing over, Sunshine
  #     HANGS FOREVER: it logs "[portalgrab] Could not create RemoteDesktop
  #     session ... No such interface" and then never finishes startup — no web
  #     UI, nothing listening on 47984/47989/47990, main loop never reached.
  #     Pinning wlr skips the portal path entirely and it uses
  #     zwlr_screencopy_manager_v1, which Hyprland does export.
  #
  #   encoder = vaapi
  #     The AMD Strix Halo iGPU. Verified to yield h264_vaapi + hevc_vaapi +
  #     av1_vaapi. Pinning skips the futile nvenc/vulkan probes at startup;
  #     Sunshine still falls back to auto-detection if vaapi ever stops working.
  #
  #   csrf_allowed_origins = <tailnet origins>
  #     Sunshine's CSRF defaults only trust localhost (https://localhost,
  #     https://127.0.0.1, https://[::1]). The whole point here is to reach the
  #     web UI from the Mac ACROSS the tailnet, and any such origin is rejected
  #     with "The request was blocked by CSRF protection" -- so pairing (a
  #     state-changing POST) is impossible until the origin is listed. Covers
  #     the Tailscale IP, the MagicDNS FQDN, and the bare hostname, since which
  #     one you land on depends on how you typed the URL. Format is a bare
  #     comma-separated list -- NOT a JSON/TOML array; brackets or quotes are
  #     rejected as "Invalid 'csrf_allowed_origins' entry". Ports optional.
  #
  # This file is a read-only /nix/store symlink, so the web UI's Configuration
  # page cannot save over it — change settings HERE and rebuild. The rest of
  # ~/.config/sunshine (certs, credentials.json, apps.json, sunshine_state.json)
  # is a normal writable dir, so pairing and app edits persist as usual.
  # Sunshine's app list. Sunshine seeds this with sample entries that are all
  # wrong for this box, and they surface in Moonlight as extra tiles that fail:
  #
  #   "Low Res Desktop"  a SECOND "Desktop"-looking tile whose prep-cmd is
  #                      `xrandr --output HDMI-1 --mode 1920x1080`. xrandr is
  #                      X11 (this is Wayland), and the output is DP-1, not
  #                      HDMI-1. The prep-cmd fails, so Sunshine refuses the
  #                      launch and Moonlight reports the useless "failed to
  #                      start the specified application (desktop)".
  #   "Steam Big Picture" there is no steam binary here.
  #
  # So: just Desktop. Note this is the app LIST only — the streamed resolution
  # is negotiated by the CLIENT (set it in Moonlight's settings); Sunshine
  # captures DP-1 at its native 3840x2160 regardless.
  #
  # Trade-off of declaring this: the file becomes a read-only store symlink, so
  # the web UI's Applications editor can no longer save. Add apps HERE instead.
  # (Pairing, certs and sunshine_state.json are separate writable files, so
  # those still work normally.)
  xdg.configFile."sunshine/apps.json" = {
    force = true;
    text = builtins.toJSON {
      env = { PATH = "$(PATH):$(HOME)/.local/bin"; };
      apps = [
        { name = "Desktop"; image-path = "desktop.png"; }
      ];
    };
  };

  # force: Sunshine writes a default sunshine.conf itself on first run, which
  # would make activation fail with "Existing file ... would be clobbered". This
  # file is declaratively owned, so overwrite it (same reason hypridle.conf and
  # monitors.conf above set force).
  xdg.configFile."sunshine/sunshine.conf" = {
    force = true;
    text = ''
      capture = wlr
      encoder = vaapi
      min_log_level = 2
      csrf_allowed_origins = https://100.122.125.84,https://omarchy.tailc143b.ts.net,https://omarchy

      # `sunshine --creds` FAILS SILENTLY without this. Unset, it resolves the
      # credentials path somewhere unwritable, prints "New credentials have been
      # created", exits 0, and writes nothing -- so the web UI has no account to
      # authenticate against and every login is rejected. Point it at a real file.
      credentials_file = ${config.home.homeDirectory}/.config/sunshine/credentials.json

      # Sunshine gates the web UI and the pairing endpoint by ORIGIN, defaulting
      # to `lan`. Tailscale addresses are 100.64.0.0/10 (CGNAT), not RFC1918, so
      # a tailnet client is classified WAN and refused BEFORE the password is even
      # checked -- which reads exactly like wrong credentials. Both keys are
      # needed: web_ui to log in, pin to submit Moonlight's pairing code.
      origin_web_ui_allowed = wan
      origin_pin_allowed = wan
    '';
  };

  # Default terminal: Ghostty, not Omarchy's stock Alacritty. Everything that
  # opens a terminal here (SUPER+RETURN, SUPER ALT+RETURN, $TERMINAL, any app
  # spawning a terminal) goes through `xdg-terminal-exec`, which picks the first
  # valid entry in this list — so this one file is the whole switch.
  #
  # Ghostty comes from nix (home.packages above), nixGLIntel-wrapped in the Linux
  # overlay — unwrapped it dies with "Failed to create EGL display" on this
  # non-NixOS host. The overlay also repoints the desktop entry's Exec/TryExec at
  # the wrapper, which is what makes this list entry resolve to a working binary.
  # ~/.nix-profile/share is on the session XDG_DATA_DIRS, so the entry is found.
  #
  # No custom .desktop entry needed: Ghostty's com.mitchellh.ghostty.desktop has
  # no X-TerminalArg* keys, so xdg-terminal-exec honors omarchy's `--dir=` by
  # chdir'ing before exec instead of passing a flag (only alacritty/foot need the
  # custom entries Omarchy ships).
  #
  # force = true because `omarchy install terminal <x>` writes this file too;
  # nix owns it, so a rebuild restores Ghostty if that command ever rewrites it.
  xdg.configFile."xdg-terminals.list" = {
    force = true;
    text = ''
      # Terminal emulator preference order for xdg-terminal-exec
      # The first found and valid terminal will be used
      com.mitchellh.ghostty.desktop
      Alacritty.desktop
    '';
  };

  # ---------------------------------------------------------------------------
  # Mail: aerc (TUI) + himalaya (scriptable), two accounts each.
  #
  # [Work] ehu@law.virginia.edu — the UVA tenant grants no IMAP/SMTP and gates
  # third-party OAuth consent behind an admin, so both clients talk to the
  # mail-bridge user service on 127.0.0.1:1143 instead (see systemd.user.services
  # below) and send through its sendmail(1) shim. Credentials there are ignored
  # by design: the real one is the Graph access token the bridge gets from ortie.
  #
  # [Personal] eddyhu@gmail.com — the same shape, over the Gmail provider: read
  # through the bridge on 1144, send through the shim. NO PASSWORD ANYWHERE ON
  # THIS ACCOUNT. Both halves spend ortie's brokered `google` token, which
  # carries gmail.modify — and gmail.modify is enough for users.messages.send,
  # so no scope widening and no re-consent was needed to retire the app
  # password. (Gmail IMAP/SMTP would have demanded the full https://mail.google.com/
  # scope, which is why going direct was the worse trade.)
  #
  # Neither account sets a copy-to / save-copy: Exchange files a MIME /sendmail
  # in Sent Items server-side and Gmail files its own Sent copy on
  # messages.send, so having the client append one would duplicate every
  # sent message.
  #
  # binds.conf is deliberately NOT declared — it stays hand-editable.
  xdg.configFile."aerc/accounts.conf" = {
    force = true;
    # The default folder on both accounts is the low-noise view of the inbox,
    # not the inbox: Exchange's Focused (mail-bridge reads Graph's per-message
    # `inferenceClassification` and exposes Focused/Other as virtual folders over
    # INBOX's UID space) and Gmail's Priority Inbox importance marker (already an
    # IMAP folder, [Gmail]/Important). The full INBOX is one `gm`/folder switch
    # away in both cases.
    text = ''
      [Work]
      from          = Edwin Hu <ehu@law.virginia.edu>
      source        = imap+insecure://owa:x@127.0.0.1:1143
      outgoing      = ${lib.getExe pkgs.mail-bridge} sendmail --account ehu@law.virginia.edu
      default       = Focused
      cache-headers = true
      # `folders` is a WHITELIST, so INBOX is deliberately absent: Focused and
      # Other partition it exactly, and showing all three would list every
      # message twice. `Conversation History` (Teams chat archive) is dropped
      # for the same reason it is never read.
      #
      # folders-sort pins the order; without it aerc sorts alphabetically and
      # Archive would lead. enable-folders-sort defaults true, so the listed
      # names come first in this order and anything else follows -- but nothing
      # else can, because `folders` admits only these.
      folders       = Focused,Other,Drafts,Sent Items,Outbox,Archive,Junk Email,Deleted Items
      folders-sort  = Focused,Other,Drafts,Sent Items,Outbox,Archive,Junk Email,Deleted Items

      [Personal]
      from              = Edwin Hu <eddyhu@gmail.com>
      # Through mail-bridge on 1144, not Gmail IMAP. Measured on THIS operation
      # -- login, SELECT INBOX, SEARCH, FETCH 200 ENVELOPEs -- the bridge takes
      # 3ms and Gmail IMAP 1108/6449/1373ms over three runs. What aerc feels is
      # the per-folder-switch part (SELECT+SEARCH+FETCH): ~3ms against
      # 758/3269/924ms. The variance is Gmail's, and the bridge does not have it.
      #
      # Any LOGIN credentials are accepted -- the real credential is the
      # brokered Google token the bridge process holds.
      source            = imap+insecure://mail:x@127.0.0.1:1144
      # SENDING is the same shim as Work, with the Gmail provider selected: the
      # composed bytes are base64url'd into users.messages.send under the same
      # brokered token. NO APP PASSWORD, and no outgoing-cred-cmd -- gmail-rest
      # defaults its broker to `ortie -a google token show`.
      #
      # Gmail REWRITES the Message-ID on this path (it replaces any whose domain
      # the account does not own). Harmless -- Gmail files the Sent copy itself
      # and threads on its own id -- but it is why the send probe reports that
      # header rather than asserting it.
      outgoing          = ${lib.getExe pkgs.mail-bridge} sendmail --provider gmail --account eddyhu@gmail.com
      # Important leads and is the default, mirroring Focused on Work.
      #
      # Names are the bridge's, NOT Gmail IMAP's: the Gmail provider maps
      # system labels to IMAP names, so it is `Important`/`Sent`/`Spam`/`Trash`,
      # never `[Gmail]/Important`. Two gaps against the Work list, and they are
      # Gmail's model rather than an omission -- Gmail has no Outbox at all, and
      # archiving is removing the INBOX label rather than a folder, so there is
      # nothing to point Archive at. User labels are excluded for now.
      #
      # `Focused`/`Other` are excluded deliberately: bridge.ts offers them
      # whenever INBOX exists, but Gmail has no classification, so Focused would
      # be the whole inbox and Other permanently empty.
      default           = Important
      folders           = Important,Drafts,Sent,Spam,Trash
      folders-sort      = Important,Drafts,Sent,Spam,Trash
      postpone          = [Gmail]/Drafts
      cache-headers     = true
    '';
  };

  # aerc styleset, Catppuccin Mocha. aerc ships a `catppuccin` styleset but it is
  # the *Frappé* flavour (#303446 base), and this machine runs Mocha — side by
  # side the shipped one reads as a washed-out grey against the terminal. Every
  # hex below is copied from ~/.config/omarchy/current/theme/ghostty.conf (the
  # same values appear in that directory's colors.toml), so aerc tracks whatever
  # `omarchy-theme-set` last selected only insofar as it stays Mocha — a theme
  # switch does NOT repaint aerc. That is the deliberate trade: aerc reads a
  # styleset from a fixed path with no include mechanism, so following the live
  # theme would need a generated file and an activation hook. Pinning is honest.
  #
  # Mocha names, for anyone editing: base #1e1e2e, surface1 #45475a, surface2
  # #585b70, subtext0 #a6adc8, subtext1 #bac2de, text #cdd6f4, blue #89b4fa,
  # red #f38ba8, green #a6e3a1, yellow #f9e2af, pink #f5c2e7, teal #94e2d5.
  #
  # The two leading lines matter: aerc pre-seeds every styleset with defaults
  # that hardcode palette indices 12/15 (border, title, selected, pill). Without
  # the reset those bleed through as terminal-blue blocks under the hex colors.
  xdg.configFile."aerc/stylesets/catppuccin-mocha" = {
    force=true;
    text=''
      *.default = true
      *.normal  = true

      default.fg=#cdd6f4

      error.fg=#f38ba8
      warning.fg=#f9e2af
      success.fg=#a6e3a1

      # Borders are drawn as real box-drawing chars (see border-char-* in
      # aerc.conf), so unlike most stylesets the fg is what's visible here.
      border.fg=#45475a
      title.fg=#1e1e2e
      title.bg=#89b4fa
      title.bold=true
      header.fg=#89b4fa
      header.bold=true

      tab.fg=#585b70
      tab.selected.fg=#89b4fa
      tab.selected.bold=true

      # msglist styles are layered (aerc-stylesets(7) "LAYERED STYLES"): later
      # entries win, and an unset fg/bg falls through to the layer below. So the
      # read/unread contrast is the base and the flag colors ride on top of it.
      msglist_default.fg=#cdd6f4
      msglist_read.fg=#a6adc8
      msglist_unread.fg=#cdd6f4
      msglist_unread.bold=true
      msglist_answered.fg=#94e2d5
      msglist_forwarded.fg=#94e2d5
      msglist_flagged.fg=#f9e2af
      msglist_flagged.bold=true
      msglist_deleted.fg=#585b70
      msglist_deleted.dim=true
      msglist_result.fg=#a6e3a1
      msglist_result.bold=true
      msglist_thread_folded.fg=#89b4fa
      msglist_thread_context.fg=#585b70
      msglist_thread_orphan.fg=#f38ba8
      msglist_gutter.fg=#45475a
      msglist_pill.fg=#1e1e2e
      msglist_pill.bg=#89b4fa

      # Marked messages are the one thing that must survive every other layer,
      # so they get a filled background rather than a foreground color.
      msglist_marked.fg=#1e1e2e
      msglist_marked.bg=#f5c2e7

      # The cursor row: surface1 fill, not the terminal's selection color
      # (#f5e0dc rosewater), which is far too loud for a row that moves on every
      # keypress. bg only — the per-flag fg colors above stay legible on it.
      msglist_*.selected.bg=#45475a
      msglist_*.selected.bold=true

      dirlist_default.fg=#a6adc8
      dirlist_unread.fg=#cdd6f4
      dirlist_unread.bold=true
      dirlist_recent.fg=#89b4fa
      dirlist_recent.bold=true
      dirlist_*.selected.bg=#45475a
      dirlist_*.selected.bold=true

      statusline_default.fg=#bac2de
      statusline_default.bg=#45475a
      statusline_default.dim=false
      statusline_error.fg=#f38ba8
      statusline_error.bold=true
      statusline_success.fg=#a6e3a1
      statusline_success.bold=true

      completion_default.fg=#cdd6f4
      completion_*.bg=#45475a
      completion_default.selected.bg=#585b70
      completion_description.fg=#a6adc8
      completion_description.dim=true
      completion_pill.bg=#89b4fa
      completion_gutter.bg=#585b70

      part_filename.fg=#cdd6f4
      part_mimetype.fg=#a6adc8
      part_switcher.selected.bg=#45475a
      part_*.selected.bg=#45475a

      selector_focused.fg=#1e1e2e
      selector_focused.bg=#89b4fa
      selector_focused.bold=true
      selector_chooser.bold=true

      spinner.fg=#89b4fa
      stack.fg=#cdd6f4

      # [viewer] styles the built-in colorize filter, which is what renders
      # text/plain here. It does NOT touch chawan's HTML output — chawan emits
      # its own escapes and aerc passes them through untouched.
      [viewer]
      url.fg=#89b4fa
      url.underline=true
      header.fg=#89b4fa
      header.bold=true
      signature.fg=#585b70
      signature.dim=true
      diff_meta.fg=#cdd6f4
      diff_meta.bold=true
      diff_chunk.fg=#f5c2e7
      diff_chunk_func.fg=#f5c2e7
      diff_chunk_func.dim=true
      diff_add.fg=#a6e3a1
      diff_del.fg=#f38ba8
      quote_1.fg=#94e2d5
      quote_2.fg=#89b4fa
      quote_3.fg=#f5c2e7
      quote_3.dim=true
      quote_4.fg=#585b70
      quote_x.fg=#585b70
      quote_x.dim=true
    '';
  };

  # unsafe-accounts-conf is REQUIRED, not a preference: a nix-managed
  # accounts.conf is a world-readable /nix/store symlink, and aerc refuses to
  # start on anything looser than 0600 without it. home-manager's own
  # programs.aerc module asserts exactly this. It costs nothing here — the file
  # holds cred *commands*, never a credential.
  #
  # Everything else is aerc's stock [filters]: `html` is the shipped filter that
  # renders text/html through w3m (hence w3m in omarchy-packages.nix).
  #
  # text/html carries the `!` prefix, which means "skip the pager, run this as
  # the main process in aerc's embedded terminal". That is required for inline
  # images: chawan emits image escapes only to a TTY, and a piped `-d` dump
  # renders an <img> as a blank line. The cost is that chawan runs as a full TUI
  # browser inside the message view — keys go to it, `q` returns to aerc.
  #
  # Historical note, because this line has flipped twice: the STOCK `! html`
  # (w3m) was bad specifically because w3m's interactive branch sets
  # `-o display_borders=true`, so table-layout newsletters rendered as six levels
  # of box-drawing with the text shoved off-screen. That is a w3m problem, not an
  # interactive-mode problem — chawan lays the same mail out properly. So `!` is
  # back, with a different renderer behind it.
  xdg.configFile."aerc/aerc.conf" = {
    force = true;
    text = ''
      [general]
      unsafe-accounts-conf = true

      # Prefer the HTML part of a multipart/alternative message. aerc's default
      # is the reverse (text/plain first), which meant chawan almost never ran —
      # most real mail carries a plain alternative, so the rich rendering and
      # inline images this setup exists for were only reachable on the rare
      # HTML-only message. Flipping this is what makes the filter actually apply.
      #
      # Trade-off, deliberate: essentially every message now opens in chawan's
      # interactive viewer rather than the pager, so `q` is needed to get back.
      # Reverse this line first if that becomes tiresome.
      [viewer]
      alternatives = text/html,text/plain

      # `sort` is a NO-OP on both accounts and is kept only as a declaration of
      # intent. aerc's sort needs the IMAP SORT extension, which neither backend
      # advertises, and it does NOT sort client-side as a fallback: without SORT
      # it warns "SORT is not supported but requested: list messages by UID" and
      # issues a plain UID SEARCH (worker/imap/open.go). Verified at runtime on
      # both accounts — the list is in UID order regardless of this line.
      #
      # That is fine today because mail-bridge keeps UID order and arrival order
      # in agreement (its sync window used to number backfill as if it had just
      # arrived, floating April mail to the top; fixed by the per-folder floor
      # watermark). The line stays so that a future backend advertising SORT
      # sorts on the field we actually mean rather than inheriting UID order by
      # accident — but do not read it as currently doing anything.
      [ui]
      sort = -r date
      styleset-name = catppuccin-mocha

      # Fixed 22 for the sender rather than the default 20%: at this terminal
      # width 20% is ~26 columns, which is more than any real display name needs
      # and steals it from the subject, the only column whose content is
      # unbounded. subject takes the remaining space (* is the default width),
      # date is `=` (fit), so the date column is exactly as wide as the longest
      # format below and never pads.
      index-columns = flags>4,name<22,subject,date>=

      # Nerd Font flag icons. All of these are covered by Maple Mono NF (the
      # ghostty font-family) — checked with fc-match against a charset filter,
      # which falls through to another font for anything the NF patch lacks.
      # Deliberately confined to the BMP private-use block (U+E000..U+F8FF, the
      # Font Awesome 4 set) plus plain geometric shapes: the Material Design
      # icons at U+F0000+ are drawn double-width and would break the 4-column
      # flags field, since aerc measures them as one cell.
      #
      # read/unread stays geometric (● ○) rather than an envelope, because it is
      # the flag the eye scans down the whole column for and a filled disc reads
      # faster at 14px than any pictogram.
      icon-new        = ●
      icon-old        = ○
      icon-replied    = 
      icon-forwarded  = 
      icon-flagged    = 
      icon-attachment = 
      icon-draft      = 
      icon-marked     = ◆
      icon-deleted    = ✕

      # Folder icons, matched on name because the two accounts disagree about
      # everything: Exchange says "Deleted Items"/"Junk Email"/"Sent Items",
      # Gmail says "[Gmail]/Trash"/"[Gmail]/Spam"/"[Gmail]/Sent Mail". Focused
      # and Other (mail-bridge's virtual views over INBOX) share the inbox icon —
      # the name beside it is what distinguishes them.
      #
      # compactDir abbreviates parent components to their initial, so Gmail's
      # "[Superhuman]/AI/AutoArchived" fits the 22-column sidebar instead of
      # being truncated to "[Superhuman]/AI/A".
      dirlist-left = {{switch .Folder (case `^(INBOX|Focused|Other)$` "") (case `Drafts$` "") (case `Sent( Items| Mail)?$` "") (case `(Deleted Items|Trash)$` "") (case `(Junk|Spam)` "") (case `(Archive|All Mail)$` "") (case `(Important|Starred)$` "") (default "")}} {{compactDir .Folder}}

      # Real box-drawing borders. aerc's default border char is a space, so the
      # sidebar and the message view are separated by a blank column and the
      # styleset's border color has nothing to draw on.
      border-char-vertical = "│"
      border-char-horizontal = "─"

      # Date formats. The stock this-week format is "Jan 02", which is identical
      # to this-year and so tells you nothing extra about the last seven days —
      # the useful fact there is the weekday and the time. Older mail gets ISO
      # rather than "2006 Jan 02" because it sorts and scans as a fixed shape.
      timestamp-format     = 2006-01-02
      this-day-time-format = 15:04
      this-week-time-format = Mon 15:04
      this-year-time-format = Jan 02

      # Keep three rows of context below the cursor instead of letting it ride
      # the bottom edge of the list.
      msglist-scroll-offset = 3

      # Threading ON, client-side on both accounts. Neither backend advertises
      # the IMAP THREAD extension (mail-bridge: IMAP4rev1 LITERAL+ IDLE NAMESPACE
      # UNSELECT MOVE ID AUTH=PLAIN; Gmail answers `BAD Unknown command: UID
      # THREAD` even POST-auth, so this is not a pre-auth artifact), and aerc
      # builds threads itself when the server can't — lib/msgstore.go:138, no
      # key needed to force it.
      #
      # An earlier version of this comment claimed threading "would fall back to
      # client-side threading over a full header fetch" and left it off for that
      # reason. That was WRONG, and the mistake is worth recording: aerc fetches
      # BODY.PEEK[HEADER] for every visible msglist row whether threading is on
      # or off. worker/imap/fetch.go builds the fetch item list unconditionally
      # — there is no threading branch in it. So the header fetch is the price
      # of the message list, not of threading; threading adds only an in-memory
      # JWZ pass, measured at 0.23ms over 991 uids on Work and 6-8ms over 5474
      # on Personal, debounced by client-threads-delay (50ms). cache-headers is
      # true on both accounts, so each message's headers are a one-time cost.
      #
      # The real trade is that threads assemble PROGRESSIVELY: a message whose
      # header hasn't been fetched yet shows as its own row until it merges, so
      # the list re-orders slightly while scrolling. Mild here — 793 of 850
      # conversations in the Work inbox window are single messages. On Personal
      # aerc's Gmail middleware (worker/middleware/gmailworker.go) widens every
      # header fetch to the whole X-GM-THRID thread, so siblings arrive together.
      #
      # threading-by-subject stays off: subject-only grouping merges unrelated
      # "Re: Faculty lunch" threads. If the progressive reordering ever grates,
      # the real fix is server-side — mail-bridge already stores Outlook's
      # ConversationId for every row (backend.ts:16 -> uidmap.ts:106, 991/991
      # populated), so THREAD=REFERENCES is <100 lines in commands.ts with no
      # new I/O, and would match Outlook Web's own threading exactly.
      threading-enabled = true

      # Address completion on <C-o> in To/Cc/Bcc, in compose AND in forward.
      # aerc ships no address book, so without this key the completion popup is
      # empty everywhere. The backing cache is frecency over sent recipients and
      # inbox senders on both accounts; the command only ever READS the cache, so
      # it returns instantly and refreshes in the background when stale.
      #
      # Only works while edit-headers stays false (aerc's default): with headers
      # edited in the text editor, aerc documents address-book-cmd as unsupported
      # and hands completion to the editor.
      [compose]
      address-book-cmd = ${aercAddressBook}/bin/aerc-addressbook %s

      # Bodies are written in Markdown and never hard-wrapped: nvim's
      # after/ftplugin/mail.lua sets textwidth 0 and soft-wraps to the window,
      # so one paragraph stays one line all the way out.
      #
      # The converted part is added by :multipart, which the `y` bind in
      # binds.conf runs immediately before :send. The text/plain part keeps the
      # Markdown source verbatim, so :postpone stores Markdown and :recall
      # reopens Markdown — aerc's recall picks the text/plain part
      # (lib.FindPlaintext), so the HTML alternative is never what lands in the
      # editor.
      [multipart-converters]
      text/html=mail-md2html

      [filters]
      text/plain=colorize
      text/calendar=calendar
      message/delivery-status=colorize
      message/rfc822=colorize
      text/html=${aercChawanHtml}
      application/pdf=!${aercPdfPreview}
      .headers=colorize

      # `o` on a part already reached hylo, via xdg-open and the desktop mime
      # database (xdg-mime query default application/pdf => hylo.desktop).
      # Stating it here changes nothing today but makes it independent of
      # ~/.config/mimeapps.list. aerc extracts the part to a temp file and
      # appends the path.
      [openers]
      application/pdf=hylo

      # No [hooks] block: aerc's new-mail hook only fired while aerc was
      # running AND sitting in that folder. Nothing replaces it yet — see
      # the git history for the retired aercMailNotify script.
    '';
  };

  # Reply/forward templates. No template-dirs key is needed: aerc falls back
  # through ~/.config/aerc/templates before its own share dir, so dropping a
  # file with the stock name here shadows the stock one.
  #
  # Both differ from aerc's defaults in the same way — the quoted original is
  # converted to MARKDOWN rather than to the flat text `exec html` produces.
  # The stock quoted_reply already branches on OriginalMIMEType and calls the
  # shipped `html` filter (w3m), which returns a rendered PAGE: centred text,
  # [1]-style link footnotes, table rules drawn in dashes. That reads fine and
  # edits terribly, and none of it round-trips back through mail-md2html.
  # forward_as_body has no branch at all upstream, so a forwarded HTML message
  # arrives in the editor as raw tags; that is the bug this file fixes.
  #
  # trimSignature runs on the MARKDOWN, after conversion, because it matches on
  # a "-- " line that does not survive as its own line inside HTML.
  xdg.configFile."aerc/templates/quoted_reply" = {
    force = true;
    text = ''
      X-Mailer: aerc {{version}}

      On {{dateFormat (.OriginalDate | toLocal) "Mon Jan 2, 2006 at 3:04 PM MST"}}, {{.OriginalFrom | names | join ", "}} wrote:
      {{ if eq .OriginalMIMEType "text/html" -}}
      {{- exec `mail-html2md` .OriginalText | trimSignature | quote -}}
      {{- else -}}
      {{- trimSignature .OriginalText | quote -}}
      {{- end}}
      {{- with .Signature }}

      {{.}}
      {{- end }}
    '';
  };

  xdg.configFile."aerc/templates/forward_as_body" = {
    force = true;
    text = ''
      X-Mailer: aerc {{version}}

      Forwarded message from {{.OriginalFrom | names | join ", "}} on {{dateFormat (.OriginalDate | toLocal) "Mon Jan 2, 2006 at 3:04 PM MST"}}:
      {{ if eq .OriginalMIMEType "text/html" -}}
      {{- exec `mail-html2md` .OriginalText -}}
      {{- else -}}
      {{- .OriginalText -}}
      {{- end}}
      {{- with .Signature }}

      {{.}}
      {{- end }}
    '';
  };

  # himalaya 2.0.0 config schema. v2 is a pure protocol client: `display-name`,
  # `signature`, `signature-delim`, the whole `message.*` tree and the
  # `backend.*` tree are all gone, replaced by `[imap]`/`[smtp]` blocks and
  # `[mailbox.alias]`. Composition lives in the mml config below. Written by
  # hand rather than through programs.himalaya, because that module derives
  # `accounts` from accounts.email.accounts and would overwrite everything here.
  xdg.configFile."himalaya/config.toml" = {
    force = true;
    text = ''
      # v1's `-s/--page-size` default of 10 became this key; the CLI flag wins.
      envelope.list.page-size = 25

      # WORK GOES DIRECT TO MICROSOFT GRAPH — no mail-bridge in this path.
      #
      # v2 ships a native msgraph backend, and the UVA tenant DOES issue a
      # Mail-scoped Graph token to the first-party Microsoft Office client via
      # the device-code grant (verified 2026-08-12: `Mail.ReadWrite` and
      # `Mail.Send` both granted, `GET /me/messages` → 200). That kills the
      # reason the bridge existed for himalaya. One earlier assumption turned
      # out wrong and is recorded so it is not re-litigated: "the tenant grants
      # no IMAP/SMTP/OAuth" — it refuses IMAP/SMTP, but not Graph.
      #
      # aerc still uses mail-bridge (it speaks IMAP, not Graph). The bridge is
      # therefore still installed and still a user service — it is just no
      # longer on himalaya's path. Both sit on the SAME credential: the bridge
      # calls the identical `ortie -a msgraph token show` broker below and
      # speaks Graph itself, so work mail has exactly one grant behind it.
      [accounts.work]
      default = true

      # Graph's well-known folder names. The entry named `inbox` is v2's
      # implicit default when `-m` is omitted.
      mailbox.alias.inbox = "inbox"
      mailbox.alias.sent = "sentitems"
      mailbox.alias.drafts = "drafts"
      mailbox.alias.trash = "deleteditems"

      # ortie mints the access token from the stored refresh token and
      # auto-refreshes (see the ortie config below). Array form: run the
      # program directly, no shell.
      msgraph.auth.token.command = ["${lib.getExe pkgs.ortie}", "-a", "msgraph", "token", "show"]

      # No [imap] or [smtp] block. Graph both reads and sends, so `himalaya
      # msgraph message send` is the work send path — and note the shared
      # `message add` is NOT implemented for Graph; drafts go through
      # `himalaya msgraph message create`. See the email-handling skill.

      [accounts.personal]

      # Gmail LABEL IDS, not IMAP folder paths — the REST API rejects
      # `[Gmail]/Sent Mail` with `HTTP 400: Invalid label`.
      mailbox.alias.inbox = "INBOX"
      mailbox.alias.sent = "SENT"
      mailbox.alias.drafts = "DRAFT"
      mailbox.alias.trash = "TRASH"
      mailbox.alias.starred = "STARRED"
      mailbox.alias.important = "IMPORTANT"

      # THE ONLY BACKEND, since the IMAP and SMTP blocks that used to sit here
      # existed only to carry the Google app password. `--backend auto` (the
      # default) picks the first configured backend a shared command supports,
      # so with nothing else configured every `himalaya -a personal ...` now
      # goes over the REST API under the brokered token. Verified: `envelope
      # list` and `message read` both work through it.
      #
      # Same brokered-token idiom as the work account's msgraph above: ortie
      # holds the grant and refreshes it, himalaya just spends the access token.
      # Requires the gmail.modify scope on ortie's `google` account (consented
      # 2026-08-13); `gws` shares that grant.
      gmail.auth.token.command = ["${lib.getExe pkgs.ortie}", "-a", "google", "token", "show"]

    '';
  };

  # mml owns everything composition-related that himalaya v2 gave up: the
  # From identity, the reply/forward quoting, and MML -> MIME compilation.
  #
  # No `signature` key, deliberately. mml's signature is plain text prefixed
  # with an RFC 3676 sig-dash, which cannot express the work signature's HTML
  # anchors; setting one would also append it to messages that already carry
  # the HTML signature from ~/.local/share/himalaya/signatures/. The skill
  # concatenates the right .html file into the body instead.
  # ortie: OAuth 2.0 broker for the work account's Graph token.
  #
  # The refresh token is NOT in agenix: agenix secrets are immutable store
  # artifacts, and a refresh token rotates on every use. It lives in a 0600
  # state file that ortie itself rewrites on each refresh.
  #
  # Bootstrap (one time, and again if the tenant ever revokes the grant):
  #   ortie -a msgraph auth get            # prints a user code + URL
  #   <sign in at the URL with ehu@law.virginia.edu, approve>
  #   ortie -a msgraph auth resume '<device-code from the line above>'
  # After that `ortie -a msgraph token show` mints access tokens unattended.
  #
  # client-id is Microsoft Office, a first-party public client the tenant
  # already pre-consents. Third-party client ids (Thunderbird etc.) initiate
  # fine but are the ones a tenant consent policy is most likely to refuse at
  # redemption — do not "simplify" this to a generic id without re-testing.
  xdg.configFile."ortie/config.toml" = {
    force = true;
    text = ''
      [accounts.msgraph]
      default = true
      grant = "device"
      client-id = "d3590ed6-52b3-4102-aeff-aad2292ab01c"
      endpoints.device-authorization = "https://login.microsoftonline.com/b8a81d5c-5169-4b0c-a890-c4ffc7cf0c85/oauth2/v2.0/devicecode"
      endpoints.token = "https://login.microsoftonline.com/b8a81d5c-5169-4b0c-a890-c4ffc7cf0c85/oauth2/v2.0/token"
      scopes = [
        "https://graph.microsoft.com/Mail.ReadWrite",
        "https://graph.microsoft.com/Mail.Send",
        "offline_access",
      ]
      # `token show` refreshes an expired access token by itself, so every
      # consumer (himalaya, a systemd timer) gets a valid one without a
      # separate refresh step.
      auto-refresh = true

      storage.read.command = "cat ${config.xdg.stateHome}/ortie/msgraph.token"
      storage.write.command = "install -D -m600 /dev/stdin ${config.xdg.stateHome}/ortie/msgraph.token"

      # Google, brokered for `gws`, which reads GOOGLE_WORKSPACE_CLI_TOKEN as a
      # pre-obtained access token ahead of its own credential store:
      #   GOOGLE_WORKSPACE_CLI_TOKEN=$(ortie -a google token show) gws sheets ...
      #
      # WHY NOT JUST `gws auth login`. gws keeps its own encrypted credentials
      # under ~/.config/gws with a keyring backend, and that layer is what failed
      # on 2026-08-12 ("Bad Request" on a token it held). Brokering through ortie
      # removes it: one token store, the same one msgraph already uses, readable
      # by cron with no keyring in the path.
      #
      # THE 7-DAY TRAP, since this WILL look like ortie's fault when it recurs.
      # An OAuth app whose publishing status is "Testing" gets refresh tokens
      # that expire 7 days after consent — absolute, not an inactivity timer, so
      # no amount of refreshing keeps one alive. That is what killed the previous
      # grant. eddyhu-gws-cli was pushed to "In production" on 2026-08-12, after
      # which refresh tokens last until revoked or ~6 months unused. If
      # `invalid_grant` returns, check the publishing status FIRST.
      #
      # The client is gws's own installed/desktop client. Its secret stays in
      # ~/.config/gws/client_secret.json and is read by command — inlining it
      # here would put a live OAuth secret in the nix store, which is
      # world-readable.
      #
      # Bootstrap (one time):
      #   ortie -a google auth get      # opens a browser; approve as eddyhu@gmail.com
      [accounts.google]
      grant = "authorization-code"
      # client-id must be a literal — ortie accepts `.command` on the secret but
      # not on the id. It is not sensitive; the secret is, and stays in a command.
      client-id = "224133371325-9adlng070ui08l2jidjlsi2n545dj5kv.apps.googleusercontent.com"
      client-secret.command = "${lib.getExe pkgs.python3} -c \"import json;print(json.load(open('${config.xdg.configHome}/gws/client_secret.json'))['installed']['client_secret'])\""
      endpoints.authorization = "https://accounts.google.com/o/oauth2/auth"
      endpoints.token = "https://oauth2.googleapis.com/token"
      endpoints.redirection = "http://localhost:9871"
      # Sheets + Drive cover the review-queue workflow. Widen deliberately: every
      # added scope re-triggers consent and enlarges what a leaked token reaches.
      scopes = [
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive",
        # gmail.modify: mail-bridge's Gmail provider (io-gmail via himalaya).
        # Read, label add/remove (which is how Gmail expresses move/copy), and
        # messages.insert for IMAP APPEND. NOT gmail.send -- the send path is
        # unchanged and still goes out over SMTP.
        #
        # This deliberately widens the SAME client gws uses, chosen over a
        # separate ortie account: one consent and one token store, at the cost
        # that a leaked gws token now reaches the whole personal mailbox.
        "https://www.googleapis.com/auth/gmail.modify",
      ]
      auto-refresh = true

      storage.read.command = "cat ${config.xdg.stateHome}/ortie/google.token"
      storage.write.command = "install -D -m600 /dev/stdin ${config.xdg.stateHome}/ortie/google.token"
    '';
  };

  xdg.configFile."mml/config.toml" = {
    force = true;
    text = ''
      [accounts.work]
      default = true
      from = "ehu@law.virginia.edu"
      from-name = "Edwin Hu"

      [accounts.personal]
      from = "eddyhu@gmail.com"
      from-name = "Edwin Hu"
    '';
  };

  # Run the hints daemon as part of the graphical session (replaces the manual
  # `exec-once = hintsd` in ~/.config/hypr/autostart.conf). uwsm exports the
  # Wayland/D-Bus env into the systemd user manager, so graphical-session.target
  # services inherit WAYLAND_DISPLAY etc.
  # hintsd + the Claude scheduled routines. mkMerge so both can define
  # systemd.user.services (a plain attrset literal can't assign the same path
  # twice; mkMerge combines them into one definition).
  systemd.user.services = lib.mkMerge [
    # Ages out ~/.tmp per ~/dotfiles/.config/user-tmpfiles.d/scratch.conf (7d).
    # Defined here rather than `systemctl --user enable
    # systemd-tmpfiles-clean.timer`: that enable is a wants/ symlink no repo
    # tracks, so the rule file would land on a new machine and never run.
    { tmp-scratch-clean = {
      Unit.Description = "Age out stale files in ~/.tmp";
      Service = {
        Type = "oneshot";
        # Distro binary, to match the running systemd version.
        ExecStart = "/usr/bin/systemd-tmpfiles --user --clean";
      };
    }; }
    (lib.mapAttrs (_: mkRoutineService) claudeRoutines)
    { hintsd = {
    Unit = {
      Description = "Hints daemon (keyboard GUI navigation)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.hints}/bin/hintsd";
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # host-dispatch: keep exactly one always-on `claude --rc --bg` dispatcher
    # session ("omarchy:host-dispatch") alive so the Mac can route work here via
    # agent-msg. The ensure.sh + system-prompt live in dotfiles
    # (~/.claude/agents/host-dispatch/, stow-linked); ~/.config/systemd/user is
    # home-manager-managed here, so the unit is declared in nix rather than
    # dropped alongside the dotfiles copy. Mirrors dotfiles' host-dispatch.service.
    # Keep aerc's completion cache warm out of band. The query path deliberately
    # never indexes inline (a full index is four IMAP fetches, ~75s), so without
    # this the first completion after a cold cache returns nothing.
    # cli-proxy-api: the local OpenAI-compatible front end for the
    # Claude/Codex/Antigravity accounts on :8317. It was started by hand in a
    # terminal, so it lived in a transient ghostty scope and died with that
    # window — precarious for something claude-code, codex and atuin-ai all
    # depend on.
    #
    # ExecStart is the mise SHIM, not the ~/.local/bin stub: the stub runs
    # `mise use -g` first and exits non-zero if that fails, so a boot with no
    # network yet would fail the unit. The shim just execs the installed
    # version. Binary comes from scripts/setup-ai-tools.sh.
    { cli-proxy-api = {
      Unit = {
        Description = "CLIProxyAPI (OpenAI-compatible front end for CLI agent accounts)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "%h/.local/share/mise/shims/cli-proxy-api --config %h/.config/cli-proxy-api/config.yaml";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    }; }
    # atuin-ai-server: the OSS backend `atuin ai` talks to, which translates
    # atuin's own /api/cli/chat SSE protocol onto cli-proxy-api's OpenAI API —
    # so history prompts never reach Atuin's hosted service. Model + endpoint
    # config is ~/.config/atuin-ai/config.toml (dotfiles).
    #
    # --network host so that config's endpoint is plain loopback to :8317; the
    # upstream docs' host.docker.internal is a Docker-Desktop-ism. Foreground
    # (no -d) so systemd owns the lifecycle, --rm so a restart is not blocked
    # by the old container's name.
    { atuin-ai = {
      Unit = {
        Description = "Atuin AI server (self-hosted, backed by cli-proxy-api)";
        # Wants, not Requires: if the proxy is down this should still start and
        # fail per-request rather than refuse to run.
        After = [ "docker.service" "cli-proxy-api.service" ];
        Wants = [ "cli-proxy-api.service" ];
      };
      Service = {
        ExecStart = ''/usr/bin/docker run --rm --name atuin-ai --network host -v %h/.config/atuin-ai/config.toml:/etc/atuin-ai/config.toml ghcr.io/atuinsh/atuin-ai-server:latest'';
        ExecStop = "/usr/bin/docker stop atuin-ai";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    }; }
    { aerc-addressbook = {
      Unit.Description = "Rebuild the aerc frecency address book";
      Service = {
        Type = "oneshot";
        ExecStart = "${aercAddressBook}/bin/aerc-addressbook --index";
      };
    }; }
    { host-dispatch = {
      Unit = {
        Description = "Ensure host-dispatch Claude session is running";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        # KillMode=process: the default control-group teardown would kill the
        # freshly-spawned `claude ... --bg` supervisor when ensure.sh exits.
        KillMode = "process";
        ExecStart = "/bin/bash -lc %h/.claude/agents/host-dispatch/ensure.sh";
      };
    }; }
    # brscan-skey: watch the DS-740D's Start button, scan-to-PDF on press. Runs
    # in the graphical session (as the user — the udev rule grants USB access) so
    # the action writes to ~/scans. The daemon reads /opt/brother/scanner/
    # brscan-skey (symlinked to the store — one-time root step in home.packages).
    { brscan-skey = {
      Unit = {
        Description = "Brother DS-740D scan-key button watcher";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "/opt/brother/scanner/brscan-skey/brscan-skey-exe";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # swlinux dictation daemon: Parakeet STT + s1-mini cleanup, capturing the
    # OBSBOT mic via the system-default source (SWLINUX_MIC=default — the
    # "builtin" auto-pick would grab the empty analog jack on this desktop).
    # Keybinds (SUPER+;) live in dotfiles' hypr bindings.conf; models are fetched
    # by activation.swlinuxModels. s1-mini.gguf is the private tuned cleanup model
    # (placed out-of-band); if absent, cleanup is skipped (raw still works).
    # sunshine: Moonlight streaming host, so the Mac can drive this desktop
    # remotely over Tailscale (connect Moonlight to 100.122.125.84 and pair with
    # the PIN from https://localhost:47990). Must run INSIDE the graphical
    # session — it captures via zwlr_screencopy_manager_v1 and injects input via
    # zwlr_virtual_pointer_manager_v1 / zwp_virtual_keyboard_manager_v1, all of
    # which need WAYLAND_DISPLAY (uwsm exports it into the user manager).
    # /dev/uinput for gamepad emulation works because `eh` is in the `input`
    # group (same reason ydotoold works). The binary is the nixGLIntel-wrapped
    # override; `capture = wlr` comes from xdg.configFile above — see both for
    # the startup-hang and GBM/EGL traps.
    { sunshine = {
      Unit = {
        Description = "Sunshine — Moonlight game/desktop streaming host";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.sunshine}/bin/sunshine %h/.config/sunshine/sunshine.conf";
        Restart = "on-failure";
        RestartSec = 5;
        # Sunshine's own shutdown path gives itself 10s before it force-aborts
        # (and dumps core). Allow a little more than that so a normal `systemctl
        # --user stop` records a clean exit rather than a spurious failure.
        TimeoutStopSec = 20;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    { swlinux = {
      Unit = {
        Description = "swlinux dictation daemon (Parakeet STT + s1-mini cleanup)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.swlinux}/bin/swlinux daemon";
        Environment = [
          "SWLINUX_MIC=default"
          "SWLINUX_LOCAL_MODEL=${config.home.homeDirectory}/.local/share/swlinux/models/s1-mini.gguf"
        ];
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # mail-bridge: loopback IMAP bridge for the UVA mailbox, so aerc (and
    # anything else that speaks IMAP) can read and write work mail. Native IMAP
    # against that tenant is foreclosed — third-party OAuth consent is
    # admin-gated, first-party client-id borrowing fails AADSTS65002 — so this
    # daemon translates IMAP to Microsoft Graph. Long-running, so no timer.
    #
    # Auth is brokered: the bridge shells out to ortie for a Graph access token,
    # which ortie mints from the stored refresh token and refreshes by itself
    # (same broker and same grant as himalaya's msgraph backend above). Nothing
    # here depends on a browser, a signed-in web tab, or a desktop session.
    #
    # Built from the mail-bridge-src flake input (modules/shared/mail-bridge.nix),
    # so this runs a lock-pinned store path, not the ~/projects working tree.
    # The send half is `mail-bridge sendmail`, invoked by aerc's `outgoing`, not
    # by this service.
    #
    # SECURITY: binds 127.0.0.1:1143 and accepts ANY LOGIN credentials — the
    # real credential is the Graph token the process holds. startImapd refuses
    # to bind anything but loopback, so this cannot accidentally be exposed.
    { mail-bridge = {
      Unit = {
        Description = "mail-bridge — loopback IMAP bridge for the UVA mailbox";
        # Graph is the only external dependency, so the network is the only
        # precondition. Deliberately not tied to the graphical session: the
        # bridge must serve mail on a headless boot or over SSH too.
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        # ABSOLUTE store path, not a bare `ortie`: a systemd user unit gets no
        # useful PATH. The bridge spawns this command per token fetch and takes
        # stdout as the bearer; ortie's auto-refresh owns renewal.
        #
        # The surrounding double quotes are load-bearing. systemd splits an
        # unquoted Environment= on whitespace and treats each field as its own
        # assignment, so `-a msgraph token show` would be dropped with only an
        # "Invalid environment assignment" log line and the bridge would spawn
        # a bare `ortie` — verified with systemd-analyze verify.
        Environment = [
          ''"MAIL_BRIDGE_TOKEN_CMD=${lib.getExe pkgs.ortie} -a msgraph token show"''
        ];
        # The binary is self-contained (bun runtime embedded), so it needs no
        # PATH or working directory of its own.
        ExecStart =
          "${pkgs.mail-bridge}/bin/mail-bridge imapd "
          + "--account ehu@law.virginia.edu";
        # A revoked or unbootstrapped grant makes startup fail; back off rather
        # than spin, and give up for a while instead of hammering Graph.
        Restart = "on-failure";
        RestartSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    }; }
    # mail-bridge-personal: the same binary, the Gmail provider, the personal
    # mailbox. A SECOND UNIT rather than a second account in one process: the
    # work bridge is what the user reads all day, and a Gmail fault must not be
    # able to take it down. Separate process, separate port, separate UID map.
    #
    # --window 200, not the work bridge's 1000. Gmail's API returns ids from
    # messages.list and then needs one messages.get PER ID -- there is no batch
    # -- so a 1000-message window is ~1001 round trips. 200 measured at ~4.7s
    # cold; the window memo and history.list keep steady state sub-second.
    { mail-bridge-personal = {
      Unit = {
        Description = "mail-bridge — loopback IMAP bridge for the personal Gmail mailbox";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        # ortie's `google` account, which carries gmail.modify. Same quoting
        # rule as the work unit: systemd splits an unquoted Environment= on
        # whitespace and would drop every argument after `ortie`.
        Environment = [
          ''"MAIL_BRIDGE_GMAIL_TOKEN_CMD=${lib.getExe pkgs.ortie} -a google token show"''
        ];
        ExecStart =
          "${pkgs.mail-bridge}/bin/mail-bridge imapd "
          + "--provider gmail --account eddyhu@gmail.com --port 1144 --window 200";
        Restart = "on-failure";
        RestartSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    }; }
    # ydotoold: virtual uinput device daemon that `ydotool` talks to over
    # %t/.ydotool_socket. Runs as the user (not root) — /dev/uinput is reachable
    # because `eh` is in the `input` group (the same grant ydotoold relies on). This
    # is the input-synthesis half of the native Wayland "computer use" loop (see
    # the linux-computer-use skill): grim = screenshot (see), hyprctl = window /
    # system control, ydotool = keyboard + mouse (act). Client socket path is
    # exported via home.sessionVariables.YDOTOOL_SOCKET above.
    { ydotoold = {
      Unit = {
        Description = "ydotoold — uinput virtual device daemon for ydotool";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.ydotool}/bin/ydotoold --socket-path=%t/.ydotool_socket";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # joycon-pad: Bluetooth Joy-Con (L) as a macro pad — stick→pointer,
    # ZL→swlinux dictation, SL/SR→tab switch, Capture-hold→Alt-Tab. Reads the
    # hid-nintendo evdev node + drives ydotool/swlinux; `input` group grants
    # /dev/input + rumble. Config is stow-linked at ~/.config/joycon-pad/config.toml
    # (dotfiles), which the daemon prefers over its packaged default. --wait lets
    # the service start before the Joy-Con connects and bind it on (re)connect.
    # One-time pairing fix (ClassicBondedOnly=false) is manual — see the repo.
    { joycon-pad = {
      Unit = {
        Description = "joycon-pad — Joy-Con macro pad for swlinux";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "bluetooth.target" ];
      };
      Service = {
        Type = "simple";
        # swlinux is shelled out to by bare name; ydotool is also on the
        # wrapper's PATH but listed here too. YDOTOOL_SOCKET matches ydotoold.
        # (limux used to be on this PATH for the SL/SR tab binds; the daemon's
        # own config decides what those keys send now — see joycon-pad's repo.)
        Environment = [
          "YDOTOOL_SOCKET=%t/.ydotool_socket"
          "PATH=${lib.makeBinPath [ pkgs.ydotool pkgs.swlinux ]}"
        ];
        ExecStart = "${pkgs.joycon-pad}/bin/joycon-pad --wait 3600";
        # Restart=always, NOT on-failure: on device loss (Joy-Con powers off or
        # drops) the daemon's read loop logs "device read error (ENODEV)" and
        # exits 0 — a clean exit, which on-failure ignores, leaving the pad dead
        # until a manual restart. --wait is a startup-only acquire loop, so the
        # restart is what re-enters it: systemd respawns after 3s and the daemon
        # polls once a second for up to an hour, binding the new event node when
        # the Joy-Con comes back. No busy-loop risk — --wait 3600 blocks for an
        # hour before giving up, so a dead device costs ~1 respawn/hour.
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
  ];

  # Timers for the Claude scheduled routines (see claudeRoutines) + host-dispatch.
  systemd.user.timers = lib.mkMerge [
    (lib.mapAttrs (_: mkRoutineTimer) claudeRoutines)
    { tmp-scratch-clean = {
      Unit.Description = "Daily ~/.tmp cleanup";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;        # catch up after the laptop was asleep
      };
      Install.WantedBy = [ "timers.target" ];
    }; }
    { aerc-addressbook = {
      Unit.Description = "Rebuild the aerc address book a few times a day";
      Timer = {
        OnBootSec = "3min";       # after the network and mail-bridge are up
        OnUnitActiveSec = "6h";   # matches the query path's staleness window
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    }; }
    { host-dispatch = {
      Unit.Description = "Periodically ensure host-dispatch Claude session is running";
      Timer = {
        OnBootSec = "30s";
        OnUnitActiveSec = "5min";
      };
      Install.WantedBy = [ "timers.target" ];
    }; }
  ];

  # Desktop entries - only the custom ones not provided by Omarchy
  xdg.desktopEntries = {
    opencode = {
      name = "OpenCode";
      comment = "The open source AI coding agent";
      exec = "${pkgs.opencode}/bin/opencode";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/OpenCode.svg";
      categories = [ "Development" "IDE" ];
      startupNotify = true;
    };

    docker = {
      name = "Docker";
      comment = "Docker container management";
      exec = "xdg-terminal-exec --app-id=TUI.tile -e lazydocker";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Docker.svg";
      startupNotify = true;
    };

    # Morgen as a Chromium PWA (web.morgen.so) rather than the native tarball at
    # ~/.local/opt/Morgen — no per-machine binary to maintain. Trade-off: the PWA
    # can't register the morgen:// scheme or handle .ics files, so mimeType is
    # dropped (the native app was the only thing that could claim those).
    # launch-or-focus (not plain launch): these web apps have single-instance
    # behaviour on the shared profile — a second launch would open a duplicate
    # tab that Morgen shows as "inactive". Matching on the window class/title
    # ("morgen") focuses the existing window instead.
    morgen = {
      name = "Morgen";
      comment = "Calendar and Tasks";
      exec = "omarchy-launch-or-focus-webapp morgen https://web.morgen.so";
      terminal = false;
      type = "Application";
      icon = "${morgenIcon}";
      categories = [ "Utility" ];
    };

    beepertexts = {
      name = "Beeper";
      comment = "Beeper messaging app";
      exec = "beeper %U";
      terminal = false;
      type = "Application";
      icon = "beeper";
      categories = [ "Network" ];
      mimeType = [ "x-scheme-handler/beeper" ];
    };

    # hylo PDF reader (gh:edwinhu/hylo). Declared here rather than taken from
    # the AppImage's bundled .desktop so Exec points at the nixGL-wrapped `hylo`
    # on PATH and passes a local path with %f — the main process resolves the
    # opened file from argv via existsSync, so a file:// URI from %U would miss.
    # StartupWMClass=hylo matches the Electron window's app_id for Hyprland
    # window association. Made the default application/pdf handler by the
    # `xdg-mime default` line (mimeapps.list is a plain file here, not
    # home-managed, so this only rewrites the one association).
    hylo = {
      name = "hylo";
      genericName = "PDF Reader";
      comment = "PDF reader with persistent highlights and Readwise sync";
      exec = "hylo %f";
      terminal = false;
      type = "Application";
      icon = "hylo";
      categories = [ "Office" "Viewer" ];
      mimeType = [ "application/pdf" ];
      startupNotify = true;
      settings.StartupWMClass = "hylo";
    };

    # LSEG Workspace as a Chromium app on the shared Default profile, same shape
    # as morgen above: one browser process, so the browser-wide :9222 from
    # chromium-flags.conf already covers it and lseg tooling can drive the live
    # session with no per-app profile and no re-login.
    #
    # Window pattern is "refinitiv", NOT "lseg". omarchy-launch-or-focus matches
    # \bPATTERN\b case-insensitively against the Hyprland class or title, and the
    # class Chromium gives this window is
    #   chrome-workspace.refinitiv.com__web-Default
    # which contains no "lseg" at all — the obvious pattern silently never
    # matches, so every launch would open a duplicate instead of focusing.
    # Verified by launching it and reading hyprctl clients. "workspace" also
    # matches but is too generic (it would catch unrelated window titles).
    #
    # The unsupported-browser banner is hidden by a Tampermonkey userscript:
    #   https://gist.github.com/edwinhu/14c99c2fba85dc519b837c6281506332
    #
    # Deliberately NOT tracked here. nix installs Tampermonkey (forcelist policy
    # below) but cannot install a *script* into it — Tampermonkey keeps those in
    # its own extension LevelDB, with no symlink or declarative path in. A
    # .user.js in this repo would be the one file nix stores but never applies,
    # and would still need a manual import. The gist carries @updateURL, so it
    # installs once per machine and self-updates thereafter — the same pattern as
    # the VitalSource->Readwise script, which survived a machine migration
    # untouched precisely because it lived in a gist rather than a config repo.
    lseg-workspace = {
      name = "LSEG Workspace";
      comment = "LSEG Workspace Web (Refinitiv Eikon)";
      exec = "omarchy-launch-or-focus-webapp refinitiv https://workspace.refinitiv.com/web";
      terminal = false;
      type = "Application";
      icon = "${iconDir}/LSEG Workspace.png";
      categories = [ "Office" "Finance" ];
      startupNotify = true;
    };

    # Makes tel: links open Google Voice instead of Zoom. `exec` must be the
    # STORE PATH, not a bare `tel-gvoice`: GLib treats a desktop entry whose Exec
    # binary it cannot resolve as NOT INSTALLED and silently ignores the handler
    # (`gio mime x-scheme-handler/tel` then reports no default at all, and the
    # click falls through to a plain browser window).
    #
    # tel-gvoice pins --profile-directory. Chromium here has three profiles
    # (Default=Personal, Profile 1=UVA, Profile 2=NYU); launched without it the
    # profile picker appears AND the --app request is discarded, so you pick a
    # profile and get an empty window.
    #
    # The association itself is set by the `xdg-mime default` activation below —
    # ~/.config/mimeapps.list is a plain file here, not home-managed, so only
    # that one line is rewritten (same approach as hylo/application-pdf).
    google-voice = {
      name = "Google Voice";
      comment = "Place calls via Google Voice";
      exec = "${telGvoice}/bin/tel-gvoice %u";
      terminal = false;
      type = "Application";
      icon = "call-start";
      categories = [ "Network" "Telephony" ];
      mimeType = [ "x-scheme-handler/tel" ];
      startupNotify = true;
    };

    # tsui (Tailscale TUI) in a floating terminal. Full store path because sudo
    # resets PATH and won't find the user nix-profile bin. Packaged from the
    # neuralink/tsui release (modules/shared/tsui.nix); needs passwordless sudo
    # for tsui or it'll prompt in the terminal.
    tailscale = {
      name = "Tailscale";
      comment = "Tailscale VPN";
      exec = "xdg-terminal-exec --app-id=TUI.float -e sudo ${pkgs.tsui}/bin/tsui";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale.svg";
      startupNotify = true;
    };

    tailscale-admin = {
      name = "Tailscale Admin Console";
      comment = "Tailscale Admin Console";
      exec = "omarchy-launch-webapp https://login.tailscale.com/admin/machines";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale Admin Console.png";
      startupNotify = true;
    };

    youtube-music = {
      name = "YouTube Music";
      comment = "YouTube Music";
      exec = "omarchy-launch-webapp https://music.youtube.com";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/YouTube Music.png";
      startupNotify = true;
    };

    readwise-reader = {
      name = "Readwise Reader";
      comment = "Readwise Reader";
      exec = "omarchy-launch-webapp https://read.readwise.io/";
      terminal = false;
      type = "Application";
      # Absolute path to the staged PNG (deployed above at line ~403). The bare
      # name "readwise-reader" resolved to nothing — no such themed icon exists,
      # and the file is "Readwise Reader.png" (with a space) under applications/
      # icons, not an icon-theme dir. Match the other web-apps (YouTube Music, etc).
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Readwise Reader.png";
      startupNotify = true;
    };

    calculator = {
      name = "Calculator (Numr)";
      comment = "Numr - vim-style calculator";
      exec = "xdg-terminal-exec --app-id=TUI.float -e ${pkgs.numr}/bin/numr";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Calculator.svg";
      startupNotify = true;
    };

  };
}
