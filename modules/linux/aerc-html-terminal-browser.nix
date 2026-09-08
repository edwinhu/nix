# terminal-browser as aerc's HTML mail renderer, on aerc's OWN terminal.
#
# THE EMBEDDED PATH IS GONE. It ran the browser inside aerc's :term, which
# allocates a second pty and paints the child into a region of aerc's screen.
# For CELLS that relay is cheap -- nvim in the composer sends a few hundred
# bytes a frame, diffed. For IMAGES it is not: the browser hands the terminal a
# 5.75 MB frame as a file PATH in ~258 bytes, but aerc had to open, decode,
# re-encode and re-stage its own copy to composite it. Two full-frame copies per
# frame, ~170 MB/s at fifteen frames a second. That was the flashing and the lag,
# and it cost a kitty-graphics decoder in vaxis that has been removed with it.
#
# WHAT REPLACED IT: aerc's :exec-tty (modules/linux/aerc-exec-tty.nix) suspends
# aerc's UI and forks the browser as a DIRECT child on aerc's own terminal, so
# it inherits aerc's process group, is the terminal's foreground group, and
# talks to ghostty exactly as it does when run by hand. vaxis documents this
# case; aerc simply had no command for it.
#
# The document is served over loopback and its images pulled same-origin by the
# same helpers the chawan filter uses: a browser will not load an https image
# into an http document, and the mail's remote images would otherwise phone home
# from the reading pane.
{ lib
, writeText
, writeShellScript
, python3
, coreutils
, symlinkJoin
, mailServe ? ../../hosts/linux/omarchy/files/mail-serve.py
, mailInlineImages ? ../../hosts/linux/omarchy/files/mail-inline-images.py
  # terminal-browser is not in nixpkgs; it installs itself under $HOME. Keep the
  # location a parameter so a different install prefix does not need a patch.
, terminalBrowser ? "$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
  # aerc itself. The wrapper must exec the REAL binary: resolving `aerc` through
  # PATH would find the wrapper again and fork-bomb.
, aerc
}:

# TWO SCRIPTS, because :term cannot be handed the message. aerc runs a :term
# command with a pty but no stdin from the mail, so the message reaches the
# browser in two steps: `:pipe -m -b` gives the mail to the server, which
# records a URL, and `:term` then launches the browser on it. The keybinding in
# ~/dotfiles/.config/aerc/binds.conf chains the two.
let
  # PAGER KEYS. A browser binds arrows, space and PageDown to scrolling and
  # nothing else -- j and k are a pager convention it has never heard of.
  # Measured against a real aerc pane: Down and space repaint in ~0.3s, while j
  # and k produce no bytes at all, which reads as "scrolling doesn't work" even
  # though the page scrolls perfectly with the keys the browser does know.
  #
  # terminal-browser's --preload runs this in the page's isolated world before
  # load, which is the supported way to add behaviour without touching the mail.
  pagerKeys = writeText "aerc-pager-keys.js" ''
    // SMOOTH THE WHEEL. terminal-browser only scrolls by pixel-precise deltas
    // when a NATIVE SCROLL HELPER feeds it high-resolution events -- and that
    // helper is a Swift file its build compiles ONLY on macOS
    // (engine/crates/pixel-core/build.rs returns early off darwin; release.sh
    // leaves NATIVE_SCROLL_HELPER empty on Linux). With no helper the wheel
    // takes input.ts's wheelTick() path: Math.sign() times WHEEL_DETENT_PX,
    // which is 120px on Linux against 40 on macOS. Every notch is one coarse
    // 120px jump, which is what reads as a laggy, stuttering wheel -- and it is
    // equally coarse however the browser is launched, which is why the same
    // scroll through aerc and run directly measure identically.
    //
    // Nothing here can supply the helper, but the page can animate the jump:
    // swallow the wheel event and ease the same distance over a few frames.
    let target = null;
    let raf = 0;
    window.addEventListener("wheel", (e) => {
      if (e.ctrlKey) return;               // leave zoom alone
      e.preventDefault();
      e.stopPropagation();
      const from = window.scrollY;
      if (target === null) target = from;
      // deltaY arrives as the 120px detent; scale it to something a page reads
      // as a scroll rather than a leap.
      target = Math.max(
        0,
        Math.min(document.body.scrollHeight, target + e.deltaY * 0.55),
      );
      if (raf) return;
      const step = () => {
        const now = window.scrollY;
        const rest = target - now;
        if (Math.abs(rest) < 1) {
          window.scrollTo({ top: target, behavior: "instant" });
          raf = 0;
          target = null;
          return;
        }
        window.scrollTo({ top: now + rest * 0.28, behavior: "instant" });
        raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    }, { passive: false, capture: true });

    // Capture phase, so a page that handles its own keys does not swallow these.
    window.addEventListener("keydown", (e) => {
      if (e.ctrlKey || e.altKey || e.metaKey) return;
      const line = Math.max(40, Math.round(window.innerHeight * 0.12));
      const half = Math.round(window.innerHeight * 0.5);
      let dy = null;
      let abs = null;
      switch (e.key) {
        case "j": dy = line; break;
        case "k": dy = -line; break;
        case "d": dy = half; break;
        case "u": dy = -half; break;
        case "g": abs = 0; break;
        case "G": abs = document.body.scrollHeight; break;
        // q closes the window. terminal-browser's own "q" shortcut does not
        // reach it once a page is focused -- reported as "q doesn't work", and
        // Ctrl-q does nothing either -- so bind it here, in the same capture
        // phase as the pager keys, and call the documented API:
        // globalThis.terminalBrowser.quit().
        case "q":
          e.preventDefault();
          e.stopPropagation();
          globalThis.terminalBrowser?.quit?.();
          return;
        default: return;
      }
      if (abs !== null) {
        window.scrollTo({ top: abs, behavior: "instant" });
      } else {
        window.scrollBy({ top: dy, behavior: "instant" });
      }
      e.preventDefault();
      e.stopPropagation();
    }, true);
  '';

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
    # fetch from it after :pipe has returned. The next preview owns its cleanup.
    setsid python3 ${mailServe} "$DIR" > "$DIR/port" 2>/dev/null &
    SRV_PID=$!
    PORT=""
    for _ in $(seq 1 60); do
      PORT=$(tr -d '\n' < "$DIR/port" 2>/dev/null)
      [ -n "$PORT" ] && break
      sleep 0.1
    done
    [ -n "$PORT" ] || exit 1

    # Only one preview is live. Two consecutive opens leave BOTH servers and
    # dirs resident unless the next serve step consumes the previous record.
    # Check the script AND its document, not just a PID that may have been
    # reused; a pidfd keeps that check tied to the process we actually signal.
    python3 - "${urlFile}" "${mailServe}" <<'PYEOF'
import os, re, shutil, signal, sys, tempfile
from pathlib import Path

try:
    previous = os.fsdecode(Path(sys.argv[1]).read_bytes()).splitlines()
except OSError:
    previous = []
directory = previous[1] if len(previous) > 1 else ""
pid = previous[2] if len(previous) > 2 else ""
root = tempfile.gettempdir().rstrip("/")
# A truncated or stale record is not authority to remove an arbitrary path.
if (re.fullmatch(re.escape(root) + r"/aerc-mail-[A-Za-z0-9]{6}", directory)
        and os.path.realpath(directory) == directory
        and os.path.isdir(directory)
        and os.stat(directory).st_uid == os.getuid()):
    if re.fullmatch(r"[1-9][0-9]*", pid):
        try:
            fd = os.pidfd_open(int(pid))
            try:
                proc = Path("/proc") / pid
                argv = (proc / "cmdline").read_bytes().split(b"\0")[:-1]
                if (len(argv) == 3
                        and (argv[1] == os.fsencode(sys.argv[2])
                             or re.fullmatch(rb"/nix/store/[a-z0-9]{32}-mail-serve\.py", argv[1]))
                        and argv[2] == os.fsencode(directory)
                        and os.readlink(proc / "cwd") == directory
                        and proc.stat().st_uid == os.getuid()):
                    signal.pidfd_send_signal(fd, signal.SIGTERM)
            finally:
                os.close(fd)
        except (OSError, OverflowError):
            pass
    shutil.rmtree(directory)
PYEOF

    # Three lines: the URL, the document dir, and the SERVER PID.
    printf 'http://127.0.0.1:%s/index.html\n' "$PORT" > "${urlFile}"
    printf '%s\n' "$DIR" >> "${urlFile}"
    printf '%s\n' "$SRV_PID" >> "${urlFile}"
  '';

  # THE NATIVE PATH. Same mail, same browser, but in its OWN pane instead of
  # inside aerc's :term -- so terminal-browser writes its kitty frames straight
  # to ghostty and nothing decodes or re-places them.
  #
  # That is the whole difference in feel. Through aerc, every scroll is parsed,
  # decoded to pixels, re-encoded and re-transmitted, and the old placement has
  # to be deleted first: measured at 15 kitty deletes and ~0.9 MB for two
  # scrolls, with a blank frame before each replacement. Run directly there is
  # no middleman, so a scroll is one atomic replace and it does not flash.
  #
  # The cost is where the mail appears: a split pane rather than aerc's own
  # message view. Both binds exist so the trade can be judged by feel.
  launchSplit = writeShellScript "aerc-html-terminal-browser-split" ''
    export PATH=${lib.makeBinPath [ coreutils ]}:$PATH
    set -u

    BROWSER="${terminalBrowser}"
    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    if [ -z "$URL" ] || [ ! -x "$BROWSER" ]; then
      echo "no served mail, or terminal-browser is not installed"
      sleep 5; exit 1
    fi

    # Deliberately KEEPING the multiplexer environment here -- it is what lets
    # terminal-browser find a pane to split, which is exactly the mechanism the
    # in-aerc launcher has to strip.
    # Every chrome switch, same as the in-aerc launcher. Omitting --no-overlays
    # and --no-context-menu here was an oversight: terminal-browser draws its
    # toasts and HUDs over the page, which is the "extra junk on top" this
    # variant was reported with.
    exec "$BROWSER" open "$URL" \
      --split right \
      --size 0.6 \
      --preload=${pagerKeys} \
      --app-mode \
      --no-toolbar \
      --no-frame \
      --no-overlays \
      --no-context-menu
  '';

  # A WINDOW OF ITS OWN. The browser gets a fresh ghostty window and paints
  # straight to it; aerc keeps running untouched in the original one.
  #
  # WHY NOT HAND OVER AERC'S TERMINAL. Two designs were built and both fail for
  # the same reason -- painting a terminal requires being its FOREGROUND process
  # group, and nothing here can get that:
  #   * detached `:pipe -b` child opening /dev/tty: once aerc suspends, the
  #     shell that launched it owns the terminal again; the child is in a
  #     background pgrp and takes SIGTTIN the moment it reads. Observed exactly
  #     that way -- aerc suspended and no browser ever appeared.
  #   * wrapper running aerc under `set -m` and catching the stop with `fg`:
  #     `fg` never returns from a non-interactive script, verified in a real
  #     pty. `wait` is no help either: it only reports a STOPPED child when job
  #     control is on.
  # A new window needs neither, and works the same on plain ghostty as under a
  # multiplexer.
  #
  # WHY NOT AERC'S :term. That path exists (see `launch`) and is where $EDITOR
  # runs when you reply -- fine for nvim, which emits CELLS that vaxis diffs in
  # a few hundred bytes. terminal-browser emits IMAGES: a full-pane bitmap per
  # frame, which vaxis must stage and re-transmit and the terminal re-upload to
  # the GPU. That is the flashing and the lag.
  window = writeShellScript "aerc-mail-window" ''
    export PATH=${lib.makeBinPath [ coreutils ]}:$PATH
    set -u

    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    [ -n "$URL" ] || exit 0
    [ -x "${terminalBrowser}" ] || exit 0

    # Detached, so aerc's :pipe returns immediately and the window outlives it.
    # The multiplexer env is stripped: with HERDR_* set terminal-browser looks
    # for a pane to split instead of taking the terminal it was given.
    setsid env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
               -u HERDR_TAB_ID -u HERDR_CONFIG_PATH -u HERDR_BIN_PATH \
               -u TMUX -u ZELLIJ -u WEZTERM_PANE -u KITTY_WINDOW_ID \
               -u CMUX_SURFACE_ID -u CMUX_WORKSPACE_ID \
      ghostty -e "${terminalBrowser}" open "$URL" \
        --app-mode --no-toolbar --no-frame --no-overlays --no-context-menu \
        --preload=${pagerKeys} </dev/null >/dev/null 2>&1 &

    exit 0
  '';

  # The mail in the REAL browser: same served URL, opened in chromium as an
  # ordinary GUI window. For when a message needs devtools, a print dialog, or
  # simply a full desktop browser -- things a terminal renderer will not do.
  chrome = writeShellScript "aerc-mail-chrome" ''
    export PATH=${lib.makeBinPath [ coreutils ]}:$PATH
    set -u

    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    [ -n "$URL" ] || exit 0

    # Detached, so :pipe returns at once and the window outlives aerc's command.
    setsid chromium "$URL" </dev/null >/dev/null 2>&1 &
    exit 0
  '';

  # For :exec-tty -- aerc has suspended and handed us its OWN terminal, so this
  # is just "run the browser", with no pane to find and nothing to composite.
  # The multiplexer env still has to go: with HERDR_* set terminal-browser
  # hunts for a pane to split instead of taking the terminal it was given.
  tty = writeShellScript "aerc-mail-tty" ''
    export PATH=${lib.makeBinPath [ coreutils ]}:$PATH
    set -u

    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    if [ -z "$URL" ] || [ ! -x "${terminalBrowser}" ]; then
      echo "no served mail, or terminal-browser is not installed"; sleep 3; exit 1
    fi

    exec "${terminalBrowser}" open "$URL" \
      --app-mode --no-toolbar --no-frame --no-overlays --no-context-menu \
      --preload=${pagerKeys}
  '';

in
symlinkJoin {
  name = "aerc-html-terminal-browser";
  paths = [ ];
  postBuild = ''
    mkdir -p $out/bin
    ln -s ${serve} $out/bin/aerc-mail-serve
    ln -s ${launchSplit} $out/bin/aerc-html-terminal-browser-split
    ln -s ${window} $out/bin/aerc-mail-window
    ln -s ${tty} $out/bin/aerc-mail-tty
    ln -s ${chrome} $out/bin/aerc-mail-chrome
  '';
}
