# terminal-browser as aerc's HTML mail renderer, on aerc's OWN terminal.
#
# FIVE LAUNCHERS, one serve step and four ways to show what it served:
#   * aerc-mail-serve   -- inlines the message's images and serves it over
#                          loopback, recording the URL for the others;
#   * aerc-mail-tty     -- what `o` runs. aerc suspends via :exec-tty and hands
#                          over its OWN terminal; this serves the message, runs
#                          terminal-browser on that tty with no relay, and reaps
#                          the server when the browser quits;
#   * aerc-mail-window  -- the browser in a fresh ghostty window;
#   * aerc-html-terminal-browser-split -- the browser in a split pane beside aerc;
#   * aerc-mail-chrome  -- the same URL in chromium, for devtools or printing.
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

# The detached launchers (window, split, chrome) take the mail in TWO STEPS,
# because nothing hands them the message: `:pipe -m -b aerc-mail-serve` gives
# the mail to the server, which records a URL, and a second `:pipe` then
# launches the browser on it. The keybinding in
# ~/dotfiles/.config/aerc/binds.conf chains the two. aerc-mail-tty needs no
# chain -- :exec-tty expands {{.Filename}}, so it serves and opens in one go.
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

  # AN FPS COUNTER YOU CAN WATCH, because measuring this from outside took a 3-minute recording per
  # sample and still answered the wrong question twice (held arrows are discrete BY DESIGN, so their
  # frame count says nothing about wheel smoothness).
  #
  # It reports two different numbers, and the difference between them is the whole point:
  #   RAF   -- animation frames the PAGE ran. The preload's wheel easing lives here.
  #   PAINT -- how many of those actually reached the screen. The page cannot measure this, so the
  #            counter draws a digit that changes every rAF; what you SEE is the delivered rate.
  # A high RAF with a visibly stuttering SWEEP bar means the page is easing and the terminal is not
  # keeping up; a low RAF means the easing itself is not running.
  #
  # Opt in with AERC_MAIL_FPS=1 -- never on by default: it repaints a corner of every mail, which is
  # itself frame traffic, and an instrument that changes what it measures is worse than none.
  fpsOverlay = ''

    // ---- FPS overlay (AERC_MAIL_FPS=1) ----------------------------------------------------
    (() => {
      const mk = () => {
        const box = document.createElement("div");
        box.setAttribute("data-aerc-fps", "1");
        box.style.cssText = [
          "position:fixed", "top:0", "right:0", "z-index:2147483647",
          "font:14px/1.25 ui-monospace,SFMono-Regular,Menlo,monospace",
          "background:rgba(0,0,0,.82)", "color:#8f8", "padding:4px 6px",
          "white-space:pre", "pointer-events:none", "text-align:right",
        ].join(";");
        (document.body || document.documentElement).appendChild(box);
        return box;
      };

      let box = null;
      let frames = 0;
      let last = performance.now();
      let raf = 0;
      // SWEEP advances one column per animation frame. Painted at the terminal's rate, a smooth
      // sweep means frames are arriving; a sweep that jumps means they are not.
      const cells = 12;
      let sweep = 0;

      const tick = (now) => {
        frames++;
        sweep = (sweep + 1) % cells;
        if (now - last >= 500) {
          raf = Math.round((frames * 1000) / (now - last));
          frames = 0;
          last = now;
        }
        if (!box) box = mk();
        const bar = "-".repeat(sweep) + "#" + "-".repeat(cells - sweep - 1);
        box.textContent = "RAF " + String(raf).padStart(3) + " fps\n" + bar + "\ny " + Math.round(window.scrollY);
        requestAnimationFrame(tick);
      };

      const start = () => requestAnimationFrame(tick);
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start, { once: true });
      } else {
        start();
      }
    })();
  '';

  pagerKeysFps = writeText "aerc-pager-keys-fps.js"
    (builtins.readFile pagerKeys + fpsOverlay);

  # Where the serve step leaves the URL for the launch step. Per-user runtime
  # dir, not /tmp: it is already per-user and cleaned on logout.
  urlFile = "\${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url";

  # REAP A RECORDED PREVIEW. Takes the url-file path as $1, reads the three-line
  # record it holds -- url, directory, server pid -- kills that server, removes
  # its directory and then the record itself, so nothing stale is left behind.
  #
  # Two callers: the serve step, before it starts a new preview (the detached
  # launchers still depend on their server OUTLIVING them), and aerc-mail-tty,
  # once the browser the user was reading in has quit.
  #
  # A truncated or stale record is not authority to kill an arbitrary pid or
  # remove an arbitrary path, which is what every check below is for: the path
  # shape, its realpath, its owner, and -- through a pidfd, so the check stays
  # tied to the process actually signalled -- the argv and cwd of the pid.
  reap = writeShellScript "aerc-mail-reap" ''
    export PATH=${lib.makeBinPath [ python3 coreutils ]}:$PATH
    set -u

    python3 - "$1" "${mailServe}" <<'PYEOF'
import os, re, shutil, signal, sys, tempfile
from pathlib import Path

record = Path(sys.argv[1])
try:
    previous = os.fsdecode(record.read_bytes()).splitlines()
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
# The record described a preview that is gone either way now; leaving it would
# hand the next reaper a pid it must not trust.
try:
    record.unlink()
except OSError:
    pass
PYEOF
  '';

  serve = writeShellScript "aerc-mail-serve" ''
    export PATH=${lib.makeBinPath [ python3 coreutils ]}:$PATH
    set -u

    PART="$(cat)"
    DIR="$(mktemp -d -t aerc-mail-XXXXXX)"

    # 4s per image, 40 images, no zoom -- the mail renders at its authored size,
    # which is what a browser does.
    # The `||` here is a FALLBACK TO THE RAW MESSAGE, so a failing inliner does
    # not error -- it serves RFC822 as index.html and the browser renders the
    # headers as "html garbage". That is exactly what a stale call signature
    # produced: the script takes NO arguments (it reads the whole message on
    # stdin) and was still being handed `"$DIR" 4 40 1.0`.
    python3 ${mailInlineImages} <<< "$PART" > "$DIR/index.html" 2>/dev/null \
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
    ${reap} "${urlFile}"

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
  # WHY NOT AERC'S :term. That is where $EDITOR runs when you reply -- fine for
  # nvim, which emits CELLS that vaxis diffs in a few hundred bytes.
  # terminal-browser emits IMAGES: a full-pane bitmap per frame, which vaxis
  # must stage and re-transmit and the terminal re-upload to the GPU. That is
  # the flashing and the lag, and it is why `o` takes the tty instead (`tty`).
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
    export PATH=${lib.makeBinPath [ python3 coreutils ]}:$PATH
    set -u

    # TAKE THE MESSAGE DIRECTLY, AND ONLY THE MESSAGE. aerc expands
    # {{.Filename}} to the message file and this serves it SYNCHRONOUSLY before
    # opening. An earlier version fell back to the URL a previous serve left in
    # the shared file when $1 was unreadable -- which is how `o` on an unread
    # mail opened whatever was served last, up to and including a test fixture.
    # There is no fallback now: no readable message means a visible error.
    #
    # RECOVER THE RENAMED FILE. Opening an unread message marks it Seen, which
    # renames it in place -- `S` is appended to the maildir info part, so
    # `…,U=<uid>:2,` becomes `…,U=<uid>:2,S` -- while aerc still expands
    # {{.Filename}} to the path it cached BEFORE the rename. Read messages
    # already carry the flag and never move, which is why only unread ones
    # failed. Only the flags after `:2,` change, so glob the stable base.
    MSG="''${1:-}"
    if [ -n "$MSG" ] && [ ! -r "$MSG" ]; then
      base="''${MSG%:2,*}"
      if [ "$base" != "$MSG" ]; then
        for f in "$base":2,*; do
          if [ -r "$f" ]; then MSG="$f"; break; fi
        done
      fi
    fi
    if [ -z "$MSG" ] || [ ! -r "$MSG" ]; then
      echo "aerc-mail-tty: no readable message file: ''${1:-<none>}"; sleep 3; exit 1
    fi

    # Do NOT clear the url file first. Its record -- url, directory, pid -- is
    # what the serve step reads to kill the PREVIOUS preview server and delete
    # its directory; erasing it turns every open into a leaked python server
    # holding a rendered copy of a mail. Serving overwrites the record itself,
    # and a failed serve is fatal below, so there is no stale URL to read.
    ${serve} < "$MSG" || {
      echo "aerc-mail-tty: could not serve $MSG"; sleep 3; exit 1
    }
    URL=$(sed -n 1p "${urlFile}" 2>/dev/null || true)
    if [ -z "$URL" ] || [ ! -x "${terminalBrowser}" ]; then
      echo "aerc-mail-tty: serving the message failed, or terminal-browser is not installed"; sleep 3; exit 1
    fi

    # TAKE THE TERMINAL, NEVER A NEIGHBOUR. Without --no-merge, `open` first
    # adopts a browser already registered in the current multiplexer tab, or
    # any running instance as a host, and the page appears there (or nowhere)
    # while this tty sits blank -- the "opens a stale page" bug. With
    # --no-merge and an interactive tty it takes the terminal it was given.
    #
    # KEEP THE HERDR ENVIRONMENT. The engine streams frames straight into the
    # pane over HERDR_SOCKET_PATH/HERDR_PANE_ID; stripped, it falls back to
    # inline kitty frames over the pty, which under a multiplexer is the slow
    # path (measured: laggy scroll). --no-merge is what stops the pane hunt,
    # so the variables can stay.
    #
    # REAP WHEN THE USER QUITS. This was an `exec` until the preview server it
    # leaves behind became the problem: with cleanup only in the serve step, one
    # python server and one temp dir holding a rendered copy of the mail stayed
    # resident from quitting the browser until the NEXT open. Dropping the exec
    # is what buys a process to come back to, so the reaper can run on the way
    # out. The EXIT trap covers a browser killed by a signal too, and its
    # failure must never become the status the user sees.
    #
    # The browser is still the terminal's foreground process: a plain foreground
    # child inherits this script's process group, and under :exec-tty that group
    # IS the terminal's foreground group, so the keyboard reaches the browser
    # exactly as it did under exec. Backgrounding it, putting it in a new
    # session, or wrapping it in a subshell would each break that.
    trap '${reap} "${urlFile}" >/dev/null 2>&1 || true' EXIT

    # FRAME TRANSPORT. terminal-browser probes the terminal and picks File, Shared or Inline.
    # herdr advertises file_frame_transport, so the fast local path wins: the browser writes RGBA
    # into a ring of mmap'd files under ~/.tmp and hands herdr the PATH. Zero-copy on this machine,
    # and unreadable from anywhere else -- over `herdr --remote` the client is handed a path into
    # omarchy's filesystem, so the pane stays blank while the pixels sit in a file nobody opens.
    # Inline puts the (zlib-compressed) pixels in the escape stream instead, so they travel.
    #
    # OPT IN EXPLICITLY -- do not infer this. SSH_CONNECTION was tried and is WRONG: panes inherit
    # the herdr SERVER's environment, and the server is itself usually started over ssh, so that
    # test is true on the desktop too. It forced inline everywhere, which costs the zero-copy file
    # handoff and with it the eased wheel scrolling (reported 2026-09-21, same day it shipped).
    #
    # There is no environment variable that answers the real question, because the real question is
    # where the VIEWING CLIENT is, which can change after the pane starts. So the operator says so:
    #     AERC_MAIL_FRAMES=inline aerc      (or export it in the remote session)
    #
    # The transport is chosen when the terminal-browser DAEMON starts and the daemon is shared, so a
    # daemon already running under the other transport keeps it. `terminal-browser shutdown` first
    # when switching, or this variable has no effect.
    FRAMES="''${AERC_MAIL_FRAMES:-}"

    # RENDER SCALE. browserRenderScale() in the browser bundle reads TERMINAL_BROWSER_RENDER_SCALE
    # and clamps it to [0.5, layout.scale]; at scale 2 a value of 0.5 is a 16x cut in pixel bytes,
    # which matters because every frame is a FULL SURFACE: measured 2026-09-21, a 2400px scroll
    # announced 216 MB across 24 transmits of a 1984x1188 RGBA surface, 7.95x what a damage rect
    # would have needed. The browser computes a damage rect and then does not use it on the wire.
    #
    # The variable is read by the browser DAEMON, which the CLI spawns with its own process.env --
    # so it only takes effect on a daemon that actually started fresh. `terminal-browser shutdown`
    # is not instantaneous, and a leftover daemon serves the request with its OLD environment while
    # reporting the default, which cost this session three identical measurements and a nearly-false
    # conclusion that the knob was inert. Verify with /proc/<daemon-pid>/environ before believing a
    # measurement, and expect sharper text to cost sharpness at 0.5.
    #
    # Opt in: AERC_MAIL_RENDER_SCALE=0.5 aerc
    SCALE="''${AERC_MAIL_RENDER_SCALE:-}"

    # DISPLAY SCALE -- this is why mail renders as a narrow column on a HiDPI screen.
    #
    # hostDisplayScale() takes electron's screen.getDisplayNearestPoint().scaleFactor, and the
    # browser runs on the x11/XWayland ozone backend, which reports 1 on a 2x Wayland output. The
    # page then lays out at DEVICE resolution with devicePixelRatio 1: measured here, the viewport
    # came back inner=1967x442 dpr=1 where it should be 983x221 dpr=2. A marketing mail built for a
    # 600px table then covers 600/1967 -- about a third of the pane -- and every glyph is half
    # size. With TERMINAL_BROWSER_DISPLAY_SCALE=2 the same page reports 983x221 dpr=2 and the mail
    # fills the width it was designed for.
    #
    # Default 2 because the host this launcher ships to is the 2x machine; AERC_MAIL_DISPLAY_SCALE
    # overrides it, and 0 or empty leaves the browser to its own detection.
    DISPLAY_SCALE="''${AERC_MAIL_DISPLAY_SCALE:-2}"
    [ "$DISPLAY_SCALE" = "0" ] && DISPLAY_SCALE=""

    # AERC_MAIL_FPS=1 swaps in the preload that also draws the counter. One --preload is passed
    # either way, so this cannot depend on whether the browser honours two of them.
    PRELOAD="${pagerKeys}"
    [ -n "''${AERC_MAIL_FPS:-}" ] && PRELOAD="${pagerKeysFps}"

    env TERMINAL_BROWSER_NO_MERGE=1 ''${FRAMES:+TERMINAL_BROWSER_FRAMES=$FRAMES} \
      ''${SCALE:+TERMINAL_BROWSER_RENDER_SCALE=$SCALE} \
      ''${DISPLAY_SCALE:+TERMINAL_BROWSER_DISPLAY_SCALE=$DISPLAY_SCALE} \
      "${terminalBrowser}" open "$URL" --no-merge \
      --app-mode --app-name=aerc-mail-tty \
      --no-toolbar --no-frame --no-overlays --no-context-menu \
      --preload="$PRELOAD"
    status=$?
    exit "$status"
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
