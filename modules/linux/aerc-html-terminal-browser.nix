# terminal-browser inside aerc -- as a :term COMMAND, not as a text/html filter.
#
# THE CORRECTION THIS FILE EXISTS TO RECORD. An earlier version of it claimed
# terminal-browser could not work inside aerc at all. That was wrong, and the
# reason is worth stating precisely because it is not obvious: a filter and a
# :term command get different things from aerc.
#
#   aerc filter : fd0, fd1 and fd2 are all PIPES. `tty` reports "not a tty".
#   aerc :term  : fd0 is a real /dev/pts/N, exactly as nvim gets.
#
# terminal-browser works out which pane it occupies by calling ttyname() on its
# own STDIN (ownTtyPath() ?? callerTty()). With pipes there is no pts to name,
# so it fails with "could not work out which ghostty pane you are in"; with
# `< /dev/tty` it resolves the literal "/dev/tty" -- the OUTER ghostty pane --
# and paints over the whole window. Neither is aerc's message view. That is why
# it cannot be a filter, and why nvim, which only ever writes to its pty, can.
#
# Given a pts it renders inline like any other TUI: full-pane RGBA frames as
# kitty a=T with t=f. Measured through aerc's :term with the patched vaxis
# (modules/linux/aerc-vaxis-kitty.nix): 598 transmit chunks and 3 placements,
# 2,438,656 bytes of image payload re-encoded to the host. The decoder and this
# launcher are the two halves; neither is useful alone.
#
# It also needs a fuller terminal handshake than a text dumper does -- DA1,
# XTVERSION, kitty keyboard, DECRQM 1016/5522/2031, OSC 10/11, the 16-colour
# palette, in-band resize mode 2048 -- all of which vaxis already answers.
#
# The document is served over loopback and its images pulled same-origin by the
# same helpers the chawan filter uses: a browser will not load an https image
# into an http document, and the mail's remote images would otherwise phone home
# from the reading pane.
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
  # STDIN MUST BE THE REAL PTS DEVICE. terminal-browser works out which pane it
  # is in by calling ttyname() on its own STDIN (ownTtyPath() ?? callerTty()),
  # so what it inherits there decides whether it renders at all:
  #
  #   the pts itself  -> renders inline, exactly like any other TUI
  #   /dev/tty        -> hangs; ttyname() yields the literal "/dev/tty", which
  #                      matches no pane, and it waits forever
  #   a pipe or null  -> "could not work out which ghostty pane you are in"
  #
  # An aerc filter is handed the MAIL on stdin, so it must give the browser
  # something else -- and `< /dev/tty`, which is right for chawan, is the one
  # wrong answer here. Resolve the actual /dev/pts/N through stdout, which aerc
  # connects to the message view's pty, and hand the browser that.
  # AND THE MULTIPLEXER MUST BE OUT OF THE PICTURE. Given HERDR_* in the
  # environment it selects the herdr adapter and looks this pty up among herdr's
  # panes -- but aerc's message view is a pty INSIDE aerc, not a herdr pane, so
  # the lookup fails and nothing renders. aerc inherits those variables from the
  # pane it was launched in, so the filter has to drop them. With no multiplexer
  # detected and a real pts on stdin it renders inline, the way any TUI does.
  unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_TAB_ID HERDR_CONFIG_PATH HERDR_BIN_PATH
  unset TMUX ZELLIJ WEZTERM_PANE KITTY_WINDOW_ID CMUX_SURFACE_ID CMUX_WORKSPACE_ID

  # Under :term stdin is already the pts, which is the whole reason this works;
  # keep a check so a mis-invocation degrades to the raw part instead of hanging.
  BROWSER_TTY=$(readlink /proc/self/fd/0 2>/dev/null || true)
  case "$BROWSER_TTY" in
    /dev/pts/*) ;;
    *) BROWSER_TTY="" ;;
  esac
  if [ -z "$BROWSER_TTY" ]; then
    printf '%s' "$PART"
    exit 0
  fi

  "$BROWSER" open \
    --app-mode \
    --no-toolbar \
    --no-frame \
    --no-shortcuts \
    --no-overlays \
    --no-context-menu \
    --no-merge \
    "http://127.0.0.1:$PORT/index.html"
  exit 0
''
