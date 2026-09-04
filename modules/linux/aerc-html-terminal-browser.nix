# aerc's text/html filter, rendered by terminal-browser instead of chawan.
#
# WHY THIS EXISTS. Decoding a child's kitty graphics (modules/linux/aerc-vaxis-kitty.nix)
# is only worth having if something actually sends them. chawan emits sixel and
# renders this repo's mail with the two-column article layout collapsed;
# terminal-browser is a real browser engine (Electron) and emits kitty graphics
# and nothing else -- `sixel` appears nowhere in it. This filter is the consumer
# the decoder was written for.
#
# THE NAME IS LOAD-BEARING. The store path of the script below carries
# "aerc-html-terminal-browser", and aerc-vaxis-kitty.nix patches aerc to enable
# the kitty file/shared-memory transmission media ONLY for a child whose argv
# contains that marker. t=f/t=t/t=s take a filesystem path straight out of the
# child's escape stream, so a filter that echoes untrusted mail bytes must not
# have them; terminal-browser sends its own frames and stages large ones in
# shared memory, so it must. Renaming this script silently disables images.
#
# The document is served over loopback and its images are pulled same-origin by
# the same helpers the chawan filter uses: a browser will not load an https
# image into an http document, and the mail's remote images would otherwise
# phone home from the reading pane.
{ lib
, writeShellScript
, python3
, coreutils
, mailServe ? ../../hosts/linux/omarchy/files/mail-serve.py
, mailInlineImages ? ../../hosts/linux/omarchy/files/mail-inline-images.py
  # terminal-browser is not in nixpkgs; it installs itself under $HOME. Keep the
  # location a parameter so a different install prefix does not need a patch.
, terminalBrowser ? "$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
}:

writeShellScript "aerc-html-terminal-browser" ''
  export PATH=${lib.makeBinPath [ python3 coreutils ]}:$PATH
  set -u

  # Double-quoted, not escapeShellArg: the default location is under $HOME and
  # has to expand at run time, in the user's environment rather than the build's.
  BROWSER="${terminalBrowser}"
  PART="$(cat)"
  DIR="$(mktemp -d)"
  SRV=""
  cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$DIR"; }
  trap cleanup EXIT INT TERM HUP

  # 4s per image, 40 images, no zoom -- the mail renders at its authored size,
  # which is what a browser does and what scratchpad/browser-3264.png shows.
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

  # No server or no browser means no images. Fall back to the raw part rather
  # than a blank pane -- an empty message view reads as aerc hanging.
  if [ -z "$PORT" ] || [ ! -x "$BROWSER" ]; then
    printf '%s' "$PART"
    exit 0
  fi

  # --app-mode with every chrome switch off: this is a message VIEW inside
  # aerc's pane, so a toolbar, tab strip, context menu or toast would be drawn
  # over the mail and aerc's own keys would fight the browser's.
  # --no-merge because each filter invocation is its own short-lived pane;
  # merging into a neighbouring instance would render the mail into a tab of
  # some other message's window.
  "$BROWSER" open \
    --app-mode \
    --no-toolbar \
    --no-frame \
    --no-shortcuts \
    --no-overlays \
    --no-context-menu \
    --no-merge \
    "http://127.0.0.1:$PORT/index.html" < /dev/tty
  exit 0
''
