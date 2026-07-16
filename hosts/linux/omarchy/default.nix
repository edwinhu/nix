# Omarchy (Arch Linux) on Framework Desktop (AMD Ryzen AI Max, x86_64)
# Minimal nix config - dotfiles managed separately.
# Modeled on hosts/linux/alarm (the aarch64/Asahi Omarchy host); the two share
# the same Omarchy desktop-entry + package set and differ only by architecture,
# which is handled in flake.nix (userHosts + the doublecmd/beeper overlays).
{ config, pkgs, lib, user, userInfo, self, ... }:

let
  iconDir = ../../../modules/linux/desktop-icons;

  # xremap (Hyprland variant) drives the Hyper(F13) leader remaps for limux — see
  # the xremap systemd user service + xdg.configFile below. `withVariant` (NOT
  # `features`) selects the compositor connector; nixpkgs' default build is wlroots.
  xremapHypr = pkgs.xremap.override { withVariant = "hyprland"; };

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
  # bound to Hyper(F13)+V via the xremap config below (Chrome exposes no
  # enable/disable shortcut and Vimium's only command is its popup, so xremap
  # drives this). It flips Vimium's OWN mechanism: a `{pattern:"*", passKeys:""}`
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

  # Morgen ships no usable icon (its iconDir entry was a Superhuman placeholder),
  # so pull the real one from the web app's apple-touch-icon (a real 180px PNG).
  # Superhuman uses the committed iconDir Superhuman.png — a 512px raster rendered
  # from the brand SVG (rsvg-convert -w 512). The SVG itself has only a 23px
  # viewBox in a <symbol>+<use>, which icon loaders rasterize at that low res ->
  # blurry on a 2x HiDPI display; the 512px PNG stays crisp at any launcher size.
  # (The mail.superhuman.com apple-touch-icon URL returns HTML, not an image.)
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
    # Include the bun/pixi global-bin dirs (qmd etc.) and CDP_PORT so the routines'
    # morgen/superhuman calls hit the browser-wide CDP endpoint on :9222 (both the
    # web apps are pages there — see chromium-flags.conf). BUN_INSTALL keeps bun's
    # global dir on-PATH despite XDG_CACHE_HOME (see dotfiles/.shell_path).
    "PATH=%h/.local/bin:%h/.bun/bin:%h/.pixi/bin:%h/.nix-profile/bin:/usr/bin:/bin"
    "CLAUDE_CONFIG_DIR=%h/.claude"
    "BUN_INSTALL=%h/.bun"
    "CDP_PORT=9222"
  ];
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
          printf %s "/morning-briefing" | claude --rc --bg --effort medium -n "🦞 assistant" || true
          # Poke the SAME session for planning 1h later; detached so it survives
          # this oneshot exiting (KillMode=process keeps it out of the cgroup kill).
          nohup bash -c 'sleep 3600; agent-msg send "🦞 assistant" "/morning-planning"' >/dev/null 2>&1 &
        else
          claude --rc --bg --effort medium -n "🦞 assistant" </dev/null || true
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
        target=$(agent-msg list 2>/dev/null \
          | sed -n '/LOCAL/,/CLOUD/p' \
          | grep -F '🦞 assistant' \
          | grep -oE 'cse_[A-Za-z0-9]+' | head -1)
        if [ -n "''${target:-}" ] && agent-msg send "$target" "/nightly-wrapup"; then
          echo "wrapup routed into assistant session ($target)"
          exit 0
        fi
        echo "no live assistant session — spawning standalone wrapup"
        printf %s "/nightly-wrapup" | claude --rc --bg --effort medium -n nightly-wrapup
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
        printf %s "/vault-compile" | claude --rc --bg --effort medium -n vault-compile
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
        ids=$(claude agents --json 2>/dev/null \
          | jq -r '.[] | select(.name == "🦞 assistant" or .name == "morning-briefing" or .name == "nightly-wrapup") | .id')
        if [ -z "''${ids:-}" ]; then
          echo "nothing to stop"
          exit 0
        fi
        for id in $ids; do
          if claude stop "$id"; then echo "stopped $id"; else echo "FAILED to stop $id"; fi
        done
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

  # superhuman-cli TOKEN REFRESH — the ONE mechanism that keeps this deployment
  # working. Context: there is NO Superhuman Linux desktop app. Superhuman here
  # runs as the "Superhuman Mail" Chromium extension on the browser-wide CDP
  # endpoint (:9222); the CLI's native background_page token-refresh path (which
  # the macOS app provides via per-account background_page IFRAMES) does not
  # exist, so silent refresh is structurally impossible and `superhuman doctor`
  # reports UNHEALTHY. That "unhealthy" is COSMETIC and expected here.
  #
  # Symptom if nothing refreshes: provider tokens in
  # ~/.config/superhuman-cli/tokens.json expire (~hourly) and never refresh, so
  # any WRITE op (star/archive/send/draft) fails with "Authentication failed
  # (run 'superhuman account auth')". READS still work (they scrape the live
  # extension/cache), which is why this hides until a write is attempted.
  #
  # Fix: `superhuman account auth` refreshes NON-INTERACTIVELY. It reads +
  # refreshes both tokens directly from the extension service worker's in-memory
  # Credential (credential.getAuthDataInBackgroundAsync({refresh:true}) — the
  # extension's own sessions.getTokens flow): NO page navigation/reload, NO
  # focus steal. When the extension service worker is live it exits in <1s.
  # Guarded to only run when Superhuman is actually live (CDP up + a
  # mail.superhuman.com page) so it never thrashes or clobbers creds when logged
  # out. Driven by the superhuman-auth-refresh oneshot + ~45min timer below
  # (tokens last ~1h).
  #
  # WHY THE CALL IS `timeout`-BOUNDED (do not remove): the in-memory path
  # (cmdAuth -> connectToSuperhumanChrome -> listAccountsChrome) attaches to the
  # Superhuman extension's MV3 service_worker and `Runtime.evaluate`s in it to
  # read accounts. MV3 service workers idle out, and Chromium does NOT reliably
  # start a dormant/wedged extension SW on a CDP attach — when it's down, both
  # the CDP attach AND the evaluate block with NO internal timeout in the CLI
  # (v0.38.3), so `account auth` hangs indefinitely. Unbounded, that runs to the
  # unit's TimeoutStartSec and marks the unit FAILED — which surfaces as a
  # `nix run .#build-switch` failure (home-manager restarts this oneshot on
  # switch; if the SW happens to be dormant at that moment the switch reports a
  # failed service). A hang is the SAME class as the logged-out no-op the guard
  # above already skips ("no reachable sync target"), so we bound the call and
  # treat a timeout as a clean skip (exit 0); the next timer fire retries when
  # the SW is awake again (normal during active Superhuman use). A GENUINE auth
  # failure exits non-zero FAST (not via the timeout) and still fails the unit
  # loudly, so real breakage still surfaces in the journal. (An earlier revision
  # used `exec ... account auth` with no bound on the theory that v0.38.2 always
  # exited in <1s; 0.38.3's service_worker path can block, so the bound is back —
  # but now it skips-on-hang instead of failing, and never reloads the tab.)
  #
  # HISTORY: an earlier superhuman-bgpage helper (a background CDP tab at
  # mail.superhuman.com/background_page.html, stashed in a hidden Hyprland
  # special workspace) was added first, to flip `doctor` to "healthy". It was
  # REMOVED as redundant once we proved — with every background_page target
  # closed and the bgpage timer stopped — that `account auth` still refreshes
  # BOTH accounts' tokens from expired→valid AND a full draft create/delete
  # write round-trip succeeds. bgpage only satisfied doctor's cosmetic URL check
  # and never sourced tokens; auth-refresh alone is sufficient. (If you ever
  # want doctor to read "healthy" again for looks, re-add the tab — but it buys
  # nothing functional.)
  superhumanAuthRefresh = pkgs.writeShellScript "superhuman-auth-refresh" ''
    set -uo pipefail
    PORT="''${CDP_PORT:-9222}"
    # Guard: only refresh when Superhuman is actually live. If the CDP endpoint
    # is down or there's no mail.superhuman.com page target, exit 0 (logged out
    # / browser closed) — never clobber creds or spin when there's no session.
    targets=$(${pkgs.curl}/bin/curl -sf "http://127.0.0.1:$PORT/json" 2>/dev/null) || exit 0
    printf '%s' "$targets" | ${pkgs.python3}/bin/python3 -c \
      'import sys, json; sys.exit(0 if any(t.get("type") == "page" and "mail.superhuman.com" in t.get("url", "") for t in json.load(sys.stdin)) else 1)' \
      || exit 0
    # Refresh tokens non-interactively (in-memory extension path — no reload, no
    # focus steal). Bounded by `timeout` (see the block comment above): a hang
    # means the extension service worker is dormant/unreachable, so skip cleanly
    # (exit 0) and let the next timer fire retry. `timeout` returns 124 on the
    # deadline; a real auth error returns the CLI's own fast non-zero and is
    # propagated so the unit fails loudly. 20s sits well under TimeoutStartSec=90.
    timeout 20 env CDP_PORT="$PORT" ${pkgs.superhuman-cli}/bin/superhuman account auth
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "superhuman-auth-refresh: refresh timed out after 20s (extension" \
           "service worker dormant / no reachable sync target); skipping this" \
           "cycle — tokens will refresh on the next fire when Superhuman is live."
      exit 0
    fi
    exit "$rc"
  '';
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
      ++ [ brscan brscanTui vimiumToggle ];

    # host-dispatch agent dir (ensure.sh + system-prompt.md) lives in dotfiles
    # but ~/.claude is not stow-managed here, so link it in out-of-store (live-
    # editable, matches the macOS ~/.claude/agents/host-dispatch layout that
    # ensure.sh's AGENT_DIR/PROMPT_FILE expect). Consumed by the host-dispatch
    # systemd service above.
    file.".claude/agents/host-dispatch".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/.claude/agents/host-dispatch";

    # Install the AI CLIs (claude, codex, opencode, agy) idempotently on every
    # build-switch. They self-update after install, so this only fills in missing
    # installs (mirrors the macOS installAITools). PATH includes curl (installer
    # downloads) + the user bin dirs so already-installed tools are detected and
    # skipped. setup-ai-tools.sh lives in this flake, hence ${self}.
    activation.installAITools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD env \
        PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.opencode/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
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

    # Scanner launcher entry. MUST live under ~/.local/share/applications
    # (XDG_DATA_HOME): omarchy's walker only indexes that dir, not the
    # nix-profile share where xdg.desktopEntries would place it. TUI.float →
    # Hyprland floats the terminal (see files/.../system.conf). `scanner` is a
    # Papirus icon name.
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

    # Icon theme symlinks (Papirus installed via home-manager, needs symlinks)
    file.".local/share/icons/Papirus".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus";
    file.".local/share/icons/Papirus-Dark".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark";

    # Install desktop entry icons
    file.".local/share/applications/icons/OpenCode.svg".source = "${iconDir}/Docker.svg";  # Placeholder until we have OpenCode icon
    file.".local/share/applications/icons/Docker.svg".source = "${iconDir}/Docker.svg";
    file.".local/share/applications/icons/Morgen.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Beeper.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Superhuman.svg".source = "${iconDir}/Superhuman.svg";
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

  # Both CDP CLIs target the browser-wide endpoint (chromium-flags.conf, :9222).
  # superhuman-cli auto-probes 9222, but morgen-cli defaults to 9253 — point it
  # here. Host-scoped: the Mac uses native apps on 9252/9253, so this only
  # belongs on omarchy where everything shares the one Chromium CDP port.
  home.sessionVariables.CDP_PORT = "9222";

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
        "dev.limux.linux".scale_factor = 1;
        "doublecmd".scale_factor = 1;
        "org.gnome.Nautilus".scale_factor = 1;
        # Beeper: hint only conversation threads (FOCUSABLE `section` role 85)
        # plus the composer (entry role 79); require FOCUSABLE (11) + SENSITIVE
        # (24) + SHOWING (25), states_match_type 1 = ALL. See alarm for details.
        "BeeperTexts" = {
          roles = [ 85 79 ];
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
  # app window (Superhuman, Morgen, etc. launched via omarchy-launch-webapp)
  # is a page on that one endpoint — so superhuman-cli (probes 9222) and
  # morgen-cli (CDP_PORT=9222) read tokens from the live session, no per-app
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
  # while the policy is present. IDs = 1Password, Paperpile, Vimium, Superhuman,
  # Readwise (copy-url is separate — loaded unpacked via --load-extension below):
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-extensions-policy.json \
  #     /etc/chromium/policies/managed/extensions.json
  # Verify: chrome://policy (Reload policies) shows ExtensionInstallForcelist.
  xdg.configFile."chromium-flags.conf" = {
    force = true;
    text = ''
      --ozone-platform=wayland
      --ozone-platform-hint=wayland
      --enable-features=TouchpadOverscrollHistoryNavigation
      --load-extension=~/.local/share/omarchy/default/chromium/extensions/copy-url
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
  # slot; Omarchy's own defaults live in a separate file). Guarantees Superhuman
  # + Morgen — and thus the browser-wide :9222 endpoint the morgen/superhuman
  # CLIs attach to — are up for the 08:00 scheduled briefing even after a reboot.
  # launch-or-focus (not launch) won't duplicate the windows you keep open all day.
  xdg.configFile."hypr/autostart.conf" = {
    force = true;
    text = ''
      exec-once = omarchy-launch-or-focus-webapp superhuman https://mail.superhuman.com
      exec-once = omarchy-launch-or-focus-webapp morgen https://web.morgen.so
    '';
  };

  # Host-local ghostty override (included last by the shared ~/.config/ghostty/
  # config). The shared font-size 14 is tuned for macOS Retina and renders too
  # big on this 32" 4K @ scale-2 panel (and in limux's embedded libghostty), so
  # shrink it here only — macOS/alarm keep their own size.
  xdg.configFile."ghostty/local.conf".text = "font-size = 10\n";

  # Hyper(F13) leader remaps for limux — consumed by the xremap service below.
  # F13+<key> emits limux's stock Ctrl+Alt(+Shift) combo (limux can't bind F13
  # itself). Hold F13 like Cmd/Shift while tapping the key.
  # Inject vimium-toggle's absolute store path so xremap's `launch` action
  # resolves it without depending on the systemd user service's PATH.
  xdg.configFile."xremap/config.yml".text =
    builtins.replaceStrings [ "@VIMIUM_TOGGLE@" ] [ "${vimiumToggle}/bin/vimium-toggle" ]
      (builtins.readFile ./files/xremap.yml);

  # Run the hints daemon as part of the graphical session (replaces the manual
  # `exec-once = hintsd` in ~/.config/hypr/autostart.conf). uwsm exports the
  # Wayland/D-Bus env into the systemd user manager, so graphical-session.target
  # services inherit WAYLAND_DISPLAY etc.
  # hintsd + the Claude scheduled routines. mkMerge so both can define
  # systemd.user.services (a plain attrset literal can't assign the same path
  # twice; mkMerge combines them into one definition).
  systemd.user.services = lib.mkMerge [
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
    # xremap: Hyper(F13) leader -> limux combos (config: xdg.configFile above).
    # HYPRLAND_INSTANCE_SIGNATURE comes from the graphical-session user env (uwsm);
    # /dev/uinput is reachable because `eh` is in the `input` group. --watch
    # re-grabs devices on hotplug (the Glove80 exposes 1 node on BT, 2 on USB).
    { xremap = {
      Unit = {
        Description = "xremap — Hyper(F13) leader remaps for limux";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${xremapHypr}/bin/xremap --watch %h/.config/xremap/config.yml";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # swlinux dictation daemon: Parakeet STT + s1-mini cleanup, capturing the
    # OBSBOT mic via the system-default source (SWLINUX_MIC=default — the
    # "builtin" auto-pick would grab the empty analog jack on this desktop).
    # Keybinds (SUPER+;) live in dotfiles' hypr bindings.conf; models are fetched
    # by activation.swlinuxModels. s1-mini.gguf is the private tuned cleanup model
    # (placed out-of-band); if absent, cleanup is skipped (raw still works).
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
    # superhuman-auth-refresh: refresh superhuman-cli OAuth tokens so WRITE ops
    # (star/archive/send/draft) keep working. This is the ONLY superhuman
    # keep-alive — see the superhumanAuthRefresh let-binding (the earlier
    # superhuman-bgpage helper was removed as redundant). Oneshot; ~45min timer
    # below (tokens last ~1h). With v0.38.2 the refresh is in-memory, exits in
    # <1s and never reloads a tab; TimeoutStartSec below is just a safety ceiling
    # (if a future build ever hangs, the unit fails loudly instead of wedging).
    # No-op when logged out.
    { superhuman-auth-refresh = {
      Unit = {
        Description = "Refresh superhuman-cli OAuth tokens (keeps writes working)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        Environment = [ "CDP_PORT=9222" ];
        # Safety ceiling only — the v0.38.2 in-memory refresh exits in <1s.
        TimeoutStartSec = 90;
        ExecStart = "${superhumanAuthRefresh}";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
    # ydotoold: virtual uinput device daemon that `ydotool` talks to over
    # %t/.ydotool_socket. Runs as the user (not root) — /dev/uinput is reachable
    # because `eh` is in the `input` group (the same grant xremap relies on). This
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
    # ZL→swlinux dictation, SL/SR→limux tabs, Capture-hold→Alt-Tab. Reads the
    # hid-nintendo evdev node + drives ydotool/swlinux/limux; `input` group grants
    # /dev/input + rumble. Config is stow-linked at ~/.config/joycon-pad/config.toml
    # (dotfiles), which the daemon prefers over its packaged default. --wait lets
    # the service start before the Joy-Con connects and bind it on (re)connect.
    # One-time pairing fix (ClassicBondedOnly=false) is manual — see the repo.
    { joycon-pad = {
      Unit = {
        Description = "joycon-pad — Joy-Con macro pad for swlinux + limux";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" "bluetooth.target" ];
      };
      Service = {
        Type = "simple";
        # swlinux + limux are shelled out to by bare name; ydotool is also on the
        # wrapper's PATH but listed here too. YDOTOOL_SOCKET matches ydotoold.
        Environment = [
          "YDOTOOL_SOCKET=%t/.ydotool_socket"
          "PATH=${lib.makeBinPath [ pkgs.ydotool pkgs.swlinux pkgs.limux ]}"
        ];
        ExecStart = "${pkgs.joycon-pad}/bin/joycon-pad --wait 3600";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    }; }
  ];

  # Timers for the Claude scheduled routines (see claudeRoutines) + host-dispatch.
  systemd.user.timers = lib.mkMerge [
    (lib.mapAttrs (_: mkRoutineTimer) claudeRoutines)
    { host-dispatch = {
      Unit.Description = "Periodically ensure host-dispatch Claude session is running";
      Timer = {
        OnBootSec = "30s";
        OnUnitActiveSec = "5min";
      };
      Install.WantedBy = [ "timers.target" ];
    }; }
    # Periodically refresh superhuman-cli OAuth tokens (see
    # superhuman-auth-refresh.service). Tokens last ~1h; refresh every ~45min
    # with a small headroom so writes never hit an expired token. ~4min after
    # boot.
    { superhuman-auth-refresh = {
      Unit.Description = "Periodically refresh superhuman-cli OAuth tokens";
      Timer = {
        OnBootSec = "4min";
        OnUnitActiveSec = "45min";
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

    # Superhuman as a Chromium app on the shared Default profile (where you're
    # already logged in). CDP is enabled browser-wide via chromium-flags.conf
    # below (one endpoint on :9222), so superhuman-cli attaches there — no
    # per-app profile or hardcoded --app-id needed.
    superhuman = {
      name = "Superhuman";
      comment = "Superhuman email client";
      exec = "omarchy-launch-or-focus-webapp superhuman https://mail.superhuman.com";
      terminal = false;
      type = "Application";
      icon = "${iconDir}/Superhuman.png";
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
