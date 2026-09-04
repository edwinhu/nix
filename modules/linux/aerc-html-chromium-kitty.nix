# aerc's text/html filter, rendered by a real browser engine and delivered as a
# kitty graphic.
#
# WHY. terminal-browser was the intended consumer for the kitty decoder in
# modules/linux/aerc-vaxis-kitty.nix and it cannot be one: it renders into a
# pane it identifies through ghostty/herdr, never into the pty a filter is
# handed (see modules/linux/aerc-html-terminal-browser.nix for the measurement).
# The decoder is sound; what was missing is something that aims a browser at
# this pty. Headless Chromium does exactly that -- it renders the mail with the
# same engine and hands back a PNG, which this filter transmits as one kitty
# a=T frame for the patched vaxis to decode.
#
# THE TRADE, stated plainly: the pane shows a picture of the mail. Layout and
# images are exactly what a browser produces -- the two-column article grid that
# chawan collapses survives -- but the text is pixels, so it is not selectable
# and terminal search does not reach it. chawan remains the better choice when
# the text matters more than the layout; this one is for mail that is mostly
# design.
#
# Inline (t=d) rather than t=f on purpose: the file media is gated off in the
# library because a path out of a child's escape stream is an arbitrary-file
# read, and a filter that only ever sends its own render has no need of it.
{ lib
, writeShellScript
, python3
, coreutils
, chromium
, mailServe ? ../../hosts/linux/omarchy/files/mail-serve.py
, mailInlineImages ? ../../hosts/linux/omarchy/files/mail-inline-images.py
}:

writeShellScript "aerc-html-chromium-kitty" ''
  export PATH=${lib.makeBinPath [ python3 coreutils chromium ]}:$PATH
  set -u

  PART="$(cat)"
  DIR="$(mktemp -d)"
  SRV=""
  cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$DIR"; }
  trap cleanup EXIT INT TERM HUP

  # Same prefetch the chawan filter uses: a browser will not load an https image
  # into an http document, and the mail's remote images would otherwise phone
  # home from the reading pane.
  python3 ${mailInlineImages} "$DIR" 4 40 1.0 <<< "$PART" > "$DIR/index.html" 2>/dev/null \
    || printf '%s' "$PART" > "$DIR/index.html"

  python3 ${mailServe} "$DIR" > "$DIR/port" 2>/dev/null &
  SRV=$!
  PORT=""
  for _ in $(seq 1 40); do
    PORT=$(tr -d '\n' < "$DIR/port" 2>/dev/null)
    [ -n "$PORT" ] && break
    sleep 0.1
  done

  # Ask the terminal how big a cell is, the same way the chawan filter does, so
  # the render matches the pane instead of a guess.
  CW=16; CH=36
  GEOM=$(python3 ${../../hosts/linux/omarchy/files/term-cell-size.py} 2>/dev/null) || GEOM=""
  [ -n "$GEOM" ] && read -r CW CH <<<"$GEOM"
  COLS=''${COLUMNS:-$(tput cols 2>/dev/null </dev/tty || echo 80)}
  ROWS=''${LINES:-$(tput lines 2>/dev/null </dev/tty || echo 24)}
  # SIZE TO THE VIEW, NOT THE TERMINAL. vaxis DISCARDS a graphic whose box
  # leaves the viewport rather than clipping it, so an image even one row too
  # tall is not drawn at all -- silently, which is the worst version of this
  # bug. The filter's own pty reports the whole terminal, and the message VIEW
  # is shorter than that by aerc's header and status rows, so leave room.
  VIEW_MARGIN=''${AERC_VIEW_MARGIN:-6}
  PX=$(( COLS * CW ))
  PY=$(( (ROWS - VIEW_MARGIN) * CH ))
  [ "$PY" -lt "$CH" ] && PY=$(( CH * 4 ))

  # No server means no render; fall back to the raw part rather than a blank
  # pane, which reads as aerc hanging.
  if [ -z "$PORT" ]; then
    printf '%s' "$PART"
    exit 0
  fi

  # --virtual-time-budget so a mail whose CDN is slow still renders instead of
  # hanging the message view.
  chromium --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
    --force-device-scale-factor=1 --virtual-time-budget=6000 \
    --window-size="$PX,$PY" --screenshot="$DIR/mail.png" \
    "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1

  if [ ! -s "$DIR/mail.png" ]; then
    printf '%s' "$PART"
    exit 0
  fi

  # One kitty frame: transmit and display in place, leaving the cursor alone.
  # Chunked at 4096 base64 bytes because that is the protocol's limit per
  # escape sequence; every chunk but the last carries m=1.
  python3 - "$DIR/mail.png" "$PX" "$PY" <<'PYEOF'
import base64, sys
png = open(sys.argv[1], "rb").read()
b64 = base64.standard_b64encode(png).decode()
w, h = sys.argv[2], sys.argv[3]
out = sys.stdout
first, CH = True, 4096
while b64:
    chunk, b64 = b64[:CH], b64[CH:]
    more = 1 if b64 else 0
    if first:
        out.write(f"\033_Ga=T,f=100,s={w},v={h},C=1,q=2,m={more};{chunk}\033\\")
        first = False
    else:
        out.write(f"\033_Gm={more};{chunk}\033\\")
out.write("\n")
out.flush()
PYEOF
  exit 0
''
