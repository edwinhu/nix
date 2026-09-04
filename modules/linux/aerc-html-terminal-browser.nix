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
, symlinkJoin
, mailServe ? ../../hosts/linux/omarchy/files/mail-serve.py
, mailInlineImages ? ../../hosts/linux/omarchy/files/mail-inline-images.py
  # terminal-browser is not in nixpkgs; it installs itself under $HOME. Keep the
  # location a parameter so a different install prefix does not need a patch.
, terminalBrowser ? "$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
}:

# TWO SCRIPTS, because :term cannot be handed the message. aerc runs a :term
# command with a pty but no stdin from the mail, so the message reaches the
# browser in two steps: `:pipe -m -b` gives the mail to the server, which
# records a URL, and `:term` then launches the browser on it. The keybinding in
# ~/dotfiles/.config/aerc/binds.conf chains the two.
let
  # Where the serve step leaves the URL for the launch step. Per-user runtime
  # dir, not /tmp: it is already per-user and cleaned on logout.
  urlFile = "\${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url";

  serve = writeShellScript "aerc-mail-serve" ''
    export PATH=${lib.makeBinPath [ python3 coreutils ]}:$PATH
    set -u

    PART="$(cat)"
    DIR="$(mktemp -d -t aerc-mail-XXXXXX)"

    # 4s per image, 40 images, no zoom -- the mail renders at its authored size,
    # which is what a browser does.
    python3 ${mailInlineImages} "$DIR" 4 40 1.0 <<< "$PART" > "$DIR/index.html" 2>/dev/null \
      || printf '%s' "$PART" > "$DIR/index.html"

    # The server outlives this script on purpose: the browser has to be able to
    # fetch from it after :pipe has returned. It exits with the document dir.
    setsid python3 ${mailServe} "$DIR" > "$DIR/port" 2>/dev/null &
    PORT=""
    for _ in $(seq 1 60); do
      PORT=$(tr -d '\n' < "$DIR/port" 2>/dev/null)
      [ -n "$PORT" ] && break
      sleep 0.1
    done
    [ -n "$PORT" ] || exit 1

    printf 'http://127.0.0.1:%s/index.html\n' "$PORT" > "${urlFile}"
    printf '%s\n' "$DIR" >> "${urlFile}"
  '';

  launch = writeShellScript "aerc-html-terminal-browser" ''
    export PATH=${lib.makeBinPath [ coreutils ]}:$PATH
    set -u

    BROWSER="${terminalBrowser}"

    # SAY SOMETHING IMMEDIATELY. terminal-browser is Electron and its cold start
    # runs to the better part of a minute before the first frame arrives; with a
    # blank pane and no cursor that is indistinguishable from aerc having hung,
    # which is exactly how it was first reported. Print before doing anything
    # slow, and name the way out, because while the browser owns this pane every
    # key except aerc's $ex prefix goes to it.
    printf '\033[2J\033[H'
    printf 'Rendering this message with terminal-browser...\n'
    printf 'Electron cold start takes ~30-60s the first time; the page replaces this text.\n\n'
    printf 'To leave: press your aerc $ex key (Ctrl-x), then type  :close  and Enter.\n'

    # THE MULTIPLEXER MUST BE OUT OF THE PICTURE. With HERDR_* (or TMUX, or a
    # kitty/wezterm pane id) in the environment terminal-browser selects that
    # adapter and looks THIS pty up among its panes. aerc's :term pty is not one
    # of them, so the lookup fails and nothing renders. Unset them and it falls
    # back to the pts on stdin, which under :term is exactly what we want.
    unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_TAB_ID \
          HERDR_CONFIG_PATH HERDR_BIN_PATH \
          TMUX ZELLIJ WEZTERM_PANE KITTY_WINDOW_ID \
          CMUX_SURFACE_ID CMUX_WORKSPACE_ID

    # stdin under :term IS the pts, and that is the whole reason this works --
    # terminal-browser names its pane with ttyname() on fd 0. Check it, so a
    # mis-invocation says so instead of hanging forever.
    TTY=$(readlink /proc/self/fd/0 2>/dev/null || true)
    case "$TTY" in
      /dev/pts/*) ;;
      *) echo "aerc-html-terminal-browser: stdin is $TTY, not a pts."
         echo "Run this through aerc's :term, not as a text/html filter --"
         echo "a filter gets pipes and terminal-browser cannot name a pane."
         echo
         echo "Press Ctrl-x then :close to leave this tab."
         sleep 10; exit 1 ;;
    esac

    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    DIR=$(sed -n 2p "${urlFile}" 2>/dev/null || true)
    if [ -z "$URL" ]; then
      echo "no mail has been served yet -- the :pipe step did not run."
      echo "Press Ctrl-x then :close to leave this tab."
      sleep 10; exit 1
    fi
    if [ ! -x "$BROWSER" ]; then
      echo "terminal-browser is not installed at $BROWSER"
      echo "Press Ctrl-x then :close to leave this tab."
      sleep 10; exit 1
    fi
    # The served copy is this message's; drop it when the browser closes.
    trap 'case "$DIR" in /tmp/aerc-mail-*) rm -rf "$DIR" ;; esac' EXIT

    # Every chrome switch off: this is a message view inside aerc's pane, so a
    # toolbar, tab strip, context menu or toast would draw over the mail and the
    # browser's keys would fight aerc's.
    "$BROWSER" open "$URL" \
      --app-mode \
      --no-toolbar \
      --no-frame \
      --no-shortcuts \
      --no-overlays \
      --no-context-menu
  '';
in
symlinkJoin {
  name = "aerc-html-terminal-browser";
  paths = [ ];
  postBuild = ''
    mkdir -p $out/bin
    ln -s ${serve} $out/bin/aerc-mail-serve
    ln -s ${launch} $out/bin/aerc-html-terminal-browser
  '';
}
