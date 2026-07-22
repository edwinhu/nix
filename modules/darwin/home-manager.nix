{ self, config, pkgs, lib, home-manager, homebrew-emacport, stylix, agenix, user, userInfo, nix-secrets, ... }:

{
  imports = [
   ./dock
   ../shared/stylix.nix
  ];

  # It me
  users.users.${user} = {
    name = "${user}";
    home = "/Users/${user}";
    isHidden = false;
    shell = pkgs.zsh;
  };

  homebrew = {
    enable = true;
    casks = pkgs.callPackage ./casks.nix {};
    brews = [
      "doxx"
      "presmihaylov/taps/ccagent"
    ];
    onActivation = {
      autoUpdate = true;
      upgrade = false;  # Disabled: breaks accessibility permissions for Karabiner/Hammerspoon
      #cleanup = "uninstall";
    };

    # These app IDs are from using the mas CLI app
    # mas = mac app store
    # https://github.com/mas-cli/mas
    #
    # $ nix shell nixpkgs#mas
    # $ mas search <app name>
    #
    # If you have previously added these apps to your Mac App Store profile (but not installed them on this system),
    # you may receive an error message "Redownload Unavailable with This Apple ID".
    # This message is safe to ignore. (https://github.com/dustinlyons/nixos-config/issues/83)

    # Nix is reinstalling these apps every time you run `darwin-rebuild switch`
    # https://github.com/nix-darwin/nix-darwin/issues/1323
    # run brew install mas to make sure you have > 2.0.0
    # All entries currently disabled — nix-darwin issue #1323: brew bundle invokes
    # `mas get <id>` on every switch, which mas 2.x no longer supports (renamed to
    # `mas info`), so installs fail even when the app is already present. Re-enable
    # individual lines once nix-darwin emits a compatible command.
    masApps = {
      # "bear" = 1091189122;
      # "microsoft to-do" = 1274495053;
      # "amazon kindle" = 302584613;
      # "microsoft word" = 462054704;
      # "microsoft excel" = 462058435;
      # "microsoft powerpoint" = 462062816;
    };
  };
  
  # Enable home-manager
  home-manager = {
    useGlobalPkgs = true;
    backupFileExtension = "backup";
    users.${user} = { pkgs, lib, config, ... }: let
      # Keeps Dia's CDP port alive without ever spawning a duplicate.
      # com.dia.cdp only fires RunAtLoad, so it loses to anything that launches
      # Dia flagless first (session restore, a URL open, another app) — the
      # flagless instance then holds the profile SingletonLock and 9222 never
      # comes up. The flag cannot be injected into a running app, so healing
      # that means restarting Dia, which this does deliberately narrowly.
      diaCdpWatchdog = pkgs.writeShellScript "dia-cdp-watchdog" ''
        set -u

        PORT=9222
        DIA_BIN="/Applications/Dia.app/Contents/MacOS/Dia"
        WRAPPER="$HOME/Applications/Dia (CDP).app"
        STAMP="$HOME/.cache/dia-cdp-watchdog.stamp"
        COOLDOWN=600   # never restart more than once per 10 min
        MAX_AGE=900    # only auto-restart a flagless Dia younger than 15 min

        log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dia-cdp-watchdog: $*" >&2; }

        # Healthy — silent exit, so the log stays free of no-op entries.
        curl -sf --max-time 5 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && exit 0

        # Not running at all: just launch it. Nothing to lose.
        if ! ps -axo comm= | grep -qx "$DIA_BIN"; then
            log "Dia not running; launching via wrapper"
            open -a "$WRAPPER"
            exit 0
        fi

        # Running but the port is down => a flagless Dia holds the SingletonLock.
        pid=$(ps -axo pid=,comm= | awk -v b="$DIA_BIN" '$2 == b { print $1; exit }')
        [ -n "$pid" ] || exit 0

        # macOS ps has no etimes, so parse etime ([[dd-]hh:]mm:ss).
        age=$(ps -p "$pid" -o etime= | tr -d ' ' | awk -F'[-:]' '
            NF==2 { print $1*60 + $2 }
            NF==3 { print $1*3600 + $2*60 + $3 }
            NF==4 { print $1*86400 + $2*3600 + $3*60 + $4 }')
        [ -n "$age" ] || age=0

        # Deliberately conservative: only restart a YOUNG Dia. That fixes the
        # launch race at login without ever killing a browser the user has been
        # working in for hours. An old Dia on a dead port is logged, not touched.
        if [ "$age" -gt "$MAX_AGE" ]; then
            log "9222 down, but Dia (pid $pid) is $age s old — leaving it alone"
            exit 0
        fi

        now=$(date +%s)
        last=$(cat "$STAMP" 2>/dev/null || echo 0)
        if [ $((now - last)) -lt $COOLDOWN ]; then
            log "9222 down; already restarted $((now - last)) s ago, within cooldown"
            exit 0
        fi
        mkdir -p "$(dirname "$STAMP")" && echo "$now" > "$STAMP"

        log "Dia (pid $pid, $age s old) is running without CDP; restarting via wrapper"
        kill -TERM "$pid"   # SIGTERM = clean Chromium shutdown; tabs are restored
        for i in $(seq 1 20); do
            ps -axo comm= | grep -qx "$DIA_BIN" || break
            sleep 1
        done
        open -a "$WRAPPER"
      '';
    in {
      imports = [
        agenix.homeManagerModules.default
        ../shared/home-secrets.nix
        ../shared/word-render.nix
        # chrome-cdp + readwise services. Cross-platform module: emits launchd
        # agents here (macOS) and systemd user services on Linux. On THIS Mac
        # only com.chrome-cdp is emitted (readerServices.enableChromeCdp = true;
        # the readwise webhook + sweep run on omarchy, the always-on primary).
        # HM now owns com.chrome-cdp declaratively — the legacy
        # activation.installChromeCdp block below no longer touches it (retired),
        # it only installs the watchdog that HM has no equivalent for.
        ../shared/reader-services.nix
      ];

      # This Mac runs chrome-cdp (native Superhuman/paper-fetch) but NOT the
      # readwise webhook + sweep — that primary lives on omarchy (the tunnel
      # points there; a second sweep would double-save).
      readerServices.enableChromeCdp = true;

      # Work around ryantm/agenix#352: Crashed=false makes launchd restart
      # the successful activation job every ten seconds on Darwin.
      launchd.agents.activate-agenix.config.KeepAlive.Crashed =
        lib.mkForce true;

      # Bring Dia up on CDP 9222 at login, through the wrapper bundle built by
      # activation.installDiaCdpApp below.
      #
      # Deliberately RunAtLoad-only, NO KeepAlive. The previous hand-written
      # ~/Library/LaunchAgents/com.dia.cdp.plist ran Dia's binary directly under
      # KeepAlive { SuccessfulExit = false; } + ThrottleInterval 30. Once a
      # flagless Dia (Dock/Spotlight) held the profile SingletonLock, every
      # respawn handed off to it and exited non-zero, so launchd started a new
      # Dia every 30s and 9222 never came up. `open` on the wrapper is
      # idempotent — the wrapper activates an existing Dia instead of spawning
      # one — and `open` exits 0, so there is nothing for KeepAlive to chase.
      #
      # Plain `open -a`, NOT `open -gja`. -g (background) and -j (hidden) make
      # Dia bounce: it comes up correctly, logs "DevTools listening on
      # ws://127.0.0.1:9222/...", fails task_policy_set TASK_CATEGORY_POLICY /
      # TASK_SUPPRESSION_POLICY, then relaunches itself seconds later as a
      # normal foreground app — WITHOUT the argv, so 9222 dies with the first
      # process. A plain foreground launch is the one path Dia does not fight.
      launchd.agents.dia-cdp = {
        enable = true;
        config = {
          Label = "com.dia.cdp";
          ProgramArguments = [
            "/usr/bin/open"
            "-a"
            "${config.home.homeDirectory}/Applications/Dia (CDP).app"
          ];
          RunAtLoad = true;
          StandardOutPath = "/tmp/dia-cdp.out.log";
          StandardErrorPath = "/tmp/dia-cdp.err.log";
        };
      };

      # Probe 9222 every 2 min and heal it. Mirrors com.chrome-cdp-watchdog
      # (which covers 9250) — launchd can only see process exit, not "process
      # is alive but the CDP socket never opened", which is exactly Dia's
      # failure mode. RunAtLoad so the first probe also closes the login race.
      launchd.agents.dia-cdp-watchdog = {
        enable = true;
        config = {
          Label = "com.dia.cdp-watchdog";
          ProgramArguments = [ "${diaCdpWatchdog}" ];
          RunAtLoad = true;
          StartInterval = 120;
          StandardOutPath = "${config.home.homeDirectory}/.local/log/dia-cdp-watchdog.log";
          StandardErrorPath = "${config.home.homeDirectory}/.local/log/dia-cdp-watchdog.log";
          EnvironmentVariables = {
            PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
            HOME = config.home.homeDirectory;
          };
          Nice = 10;
        };
      };

      home = {
        stateVersion = "25.05"; # latest stable as of 20250527
        enableNixpkgsReleaseCheck = false;
        packages = pkgs.callPackage ./packages.nix {};
        sessionVariables = {
          # Secret paths will be set by the system
        };
        # Write shell wrappers into ~/.local/bin on every build-switch.
        # Wrappers (not symlinks) because Bun's posix_spawn cannot exec nix
        # store binaries directly — their ELF interpreter lives in /nix/store
        # and posix_spawn doesn't resolve it. A shell wrapper works because
        # /bin/bash is a real system binary that posix_spawn can always find.
        # The *-update apps also write here — activation keeps them in sync.
        activation.linkLocalBin = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD mkdir -p "$HOME/.local/bin"
          # Superhuman CLI wrapper: targets the native Superhuman.app on CDP 9252.
          # Auto-kickstarts the com.user.superhuman-cdp LaunchAgent if the port is down,
          # falling back to opening the ~/Applications/Superhuman (CDP).app wrapper bundle.
          # Web Superhuman in chrome-cdp is no longer used (Cloudflare Turnstile +
          # JWT rotation made it fragile; the native app handles its own auth).
          $DRY_RUN_CMD rm -f "$HOME/.local/bin/superhuman"
          printf '%s\n' \
            '#!/bin/bash' \
            'PORT=9252' \
            'if ! curl -s --max-time 2 "http://localhost:$PORT/json/version" >/dev/null 2>&1; then' \
            '  launchctl kickstart -k "gui/$(id -u)/com.user.superhuman-cdp" 2>/dev/null \' \
            '    || open -gja "$HOME/Applications/Superhuman (CDP).app"' \
            '  for i in 1 2 3 4 5 6 7 8 9 10; do' \
            '    sleep 1' \
            '    curl -s --max-time 1 "http://localhost:$PORT/json/version" >/dev/null 2>&1 && break' \
            '  done' \
            'fi' \
            '# No `export CDP_PORT`: the CLI discovers its endpoint (Electron' \
            '# port, then Chrome/Chromium). Pinning it here would skip that probe,' \
            '# so if the desktop app failed to come up above, the CLI could no' \
            '# longer fall back to a browser session. $PORT above is only for the' \
            '# is-it-up check and the kickstart — not an instruction to the CLI.' \
            'exec "$HOME/projects/superhuman-cli/dist/superhuman-darwin" "$@"' \
            > "$HOME/.local/bin/superhuman"
          $DRY_RUN_CMD chmod +x "$HOME/.local/bin/superhuman"
        '';

        # "Dia (CDP).app" — wrapper bundle that owns Dia's launch so CDP 9222 is
        # always on. Sibling of the hand-made "Superhuman (CDP).app" (9252).
        #
        # --remote-debugging-port only applies at launch and cannot be injected
        # into a running app. A flagless Dia started from the Dock therefore
        # takes the profile SingletonLock, and every later CDP launch hands its
        # command line to that instance and exits — 9222 stays down. Under the
        # old com.dia.cdp (KeepAlive SuccessfulExit=false, ThrottleInterval 30)
        # each of those handoffs read as a failure, so launchd started a fresh
        # Dia every 30s forever. Point the Dock/Login Item at this bundle and
        # the flagless launch never happens; the agent below is RunAtLoad-only.
        activation.installDiaCdpApp = lib.hm.dag.entryAfter ["writeBoundary"] ''
          APP="$HOME/Applications/Dia (CDP).app"
          $DRY_RUN_CMD mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
          if [ -f /Applications/Dia.app/Contents/Resources/AppIcon.icns ]; then
            $DRY_RUN_CMD cp -f /Applications/Dia.app/Contents/Resources/AppIcon.icns \
              "$APP/Contents/Resources/Icon.icns"
          fi
          $DRY_RUN_CMD printf '%s\n' \
            '<?xml version="1.0" encoding="UTF-8"?>' \
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
            '<plist version="1.0">' \
            '<dict>' \
            '    <key>CFBundleExecutable</key><string>launcher</string>' \
            '    <key>CFBundleIdentifier</key><string>com.user.dia-cdp</string>' \
            '    <key>CFBundleName</key><string>Dia</string>' \
            '    <key>CFBundleDisplayName</key><string>Dia</string>' \
            '    <key>CFBundleIconFile</key><string>Icon</string>' \
            '    <key>CFBundlePackageType</key><string>APPL</string>' \
            '    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
            '    <key>CFBundleShortVersionString</key><string>1.0</string>' \
            '    <key>NSHighResolutionCapable</key><true/>' \
            '</dict>' \
            '</plist>' \
            > "$APP/Contents/Info.plist"
          $DRY_RUN_CMD printf '%s\n' \
            '#!/bin/bash' \
            '# Launch Dia.app with CDP enabled on 9222. Managed by nix —' \
            '# edit modules/darwin/home-manager.nix, not this file.' \
            'PORT=9222' \
            'DIA_BIN="/Applications/Dia.app/Contents/MacOS/Dia"' \
            '# Already running? Activate and exit — never spawn a duplicate. A' \
            '# second instance cannot take the profile SingletonLock; it aborts' \
            '# (SIGABRT), which under a KeepAlive agent becomes a relaunch loop.' \
            '#' \
            '# ps, not pgrep: pgrep needs sysmond and returns "Cannot get process' \
            '# list" in sandboxed/non-GUI contexts, where it would fail OPEN and' \
            '# fall through to the exec below. `comm=` prints the full executable' \
            '# path, so -x is an exact match and this script cannot self-match.' \
            '# open -a (not osascript) to activate: Dia is not AppleScript-' \
            '# scriptable (-1728) and osascript would need Automation TCC.' \
            'if ps -axo comm= | grep -qx "$DIA_BIN"; then' \
            '    open -a /Applications/Dia.app 2>/dev/null || true' \
            '    exit 0' \
            'fi' \
            '# exec, so this process BECOMES Dia and the Dock running indicator' \
            '# stays on this bundle instead of lighting up a second icon.' \
            '# _CFBundleIdentifier is unset so CoreFoundation resolves Dia'"'"'s main' \
            '# bundle from the executable path rather than inheriting this' \
            '# wrapper'"'"'s id — keeps Dia'"'"'s TCC/keychain identity intact.' \
            'unset _CFBundleIdentifier' \
            "exec \"\$DIA_BIN\" --remote-debugging-port=\"\$PORT\" --remote-allow-origins='*'" \
            > "$APP/Contents/MacOS/launcher"
          $DRY_RUN_CMD chmod +x "$APP/Contents/MacOS/launcher"
          $DRY_RUN_CMD touch "$APP"
        '';

        # Idempotent bootstrap for AI CLIs (claude, codex, opencode).
        # Each tool self-updates after install, so this only runs missing installs.
        # Use `nix run ~/nix#update-ai-tools` to force-bump to latest.
        # PATH must include curl (installer downloads) plus user dirs so `want()`
        # sees already-installed tools and skips reinstall.
        activation.installAITools = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD env \
            PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.opencode/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
            ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh || true
        '';

        # claude-stable: a stable HARDLINK to the live `claude` worker inode.
        # macOS-ONLY TCC workaround — Claude auto-updates repoint
        # ~/.local/bin/claude -> versions/<new>, and macOS treats each new binary
        # path as a new app, re-prompting for Full Disk Access / Photos / folders
        # every update. Grant FDA once to ~/.local/bin/claude-stable and it
        # survives updates. macbook-pro (vwh7mb) ONLY — gated on userInfo.host
        # below; mba/omarchy/alarm use plain `claude`, and the shared scripts
        # (ensure.sh, rc-watchdog, rc-recover) fall back to it there.
        #
        # This activation guarantees the link exists right after a build-switch
        # (before any interactive shell), which the launchd scheduled-tasks that
        # launch through claude-stable rely on. Between build-switches it's kept
        # fresh lazily by .shell_env and on version-change by rc-after-upgrade
        # (both refresh-only — they never CREATE the link off macbook-pro).
        activation.installClaudeStable = lib.mkIf (userInfo.host == "macbook-pro")
          (lib.hm.dag.entryAfter ["writeBoundary"] ''
          CLAUDE_LINK="$HOME/.local/bin/claude"
          CLAUDE_STABLE="$HOME/.local/bin/claude-stable"
          if [ -e "$CLAUDE_LINK" ]; then
            # Resolve the single-hop install symlink (macOS readlink has no -f).
            worker="$(readlink "$CLAUDE_LINK" 2>/dev/null || true)"
            [ -z "$worker" ] && worker="$CLAUDE_LINK"
            case "$worker" in
              /*) ;;
              *)  worker="$(dirname "$CLAUDE_LINK")/$worker" ;;
            esac
            # Re-link only when the live worker inode changed (new version).
            if [ -f "$worker" ] && ! [ "$CLAUDE_STABLE" -ef "$worker" ]; then
              $DRY_RUN_CMD mkdir -p "$HOME/.local/bin"
              $DRY_RUN_CMD ln -f "$worker" "$CLAUDE_STABLE" && echo "claude-stable -> $worker"
            fi
          else
            echo "claude-stable: $CLAUDE_LINK not present, skipping (install claude, then re-run build-switch)"
          fi
        '');

        # chrome-cdp: headless Chrome on CDP 9250 for browser automation
        # (Reader, Readwise, scraping). Source of truth lives at
        # ~/projects/chrome-cdp/. The com.chrome-cdp DAEMON agent is now managed
        # declaratively by ../shared/reader-services.nix — do NOT install or
        # bootstrap com.chrome-cdp here, or the two ping-pong over
        # ~/Library/LaunchAgents/com.chrome-cdp.plist on every build-switch.
        # This activation only: (1) symlinks the repo scripts onto PATH for
        # interactive use, and (2) installs the com.chrome-cdp-watchdog agent,
        # which has no HM equivalent — it restarts chrome-cdp when the CDP port
        # hangs while the process is still alive, a mode KeepAlive can't catch.
        activation.installChromeCdp = lib.hm.dag.entryAfter ["writeBoundary"] ''
          CHROME_CDP_REPO="$HOME/projects/chrome-cdp"
          if [ ! -d "$CHROME_CDP_REPO" ]; then
            echo "chrome-cdp: $CHROME_CDP_REPO not present, skipping (clone repo then re-run build-switch)"
          else
            $DRY_RUN_CMD mkdir -p "$HOME/.local/bin" "$HOME/.local/log" "$HOME/Library/LaunchAgents"
            # Symlink the daemon + watchdog scripts so they're on PATH (interactive
            # use; the launchd agents reference the repo path directly).
            $DRY_RUN_CMD ln -sfn "$CHROME_CDP_REPO/bin/chrome-cdp" "$HOME/.local/bin/chrome-cdp"
            $DRY_RUN_CMD ln -sfn "$CHROME_CDP_REPO/bin/chrome-cdp-watchdog" "$HOME/.local/bin/chrome-cdp-watchdog"
            # Watchdog ONLY — com.chrome-cdp is HM-managed (reader-services.nix).
            # install -m 644 is a no-op when contents already match.
            label=com.chrome-cdp-watchdog
            SRC="$CHROME_CDP_REPO/LaunchAgents/$label.plist"
            DST="$HOME/Library/LaunchAgents/$label.plist"
            if [ ! -f "$DST" ] || ! cmp -s "$SRC" "$DST"; then
              $DRY_RUN_CMD install -m 644 "$SRC" "$DST"
              # bootout may fail if not loaded yet — hence || true.
              $DRY_RUN_CMD launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
              $DRY_RUN_CMD launchctl bootstrap "gui/$(id -u)" "$DST" 2>/dev/null || true
            fi
          fi
        '';

        # Allowed-signers file for SSH-format git commit verification.
        # Both emails (work + personal) trust the active signing key (id_github)
        # plus both YubiKey FIDO2 keys (used historically and still valid).
        file.".config/git/allowed_signers".text = ''
          ehu@law.virginia.edu,eddyhu@gmail.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtcdBz0lxP0sSN0I6FIwv5Hrbm5PyTwO+LimvaJX8rZyo2XDnb87bBatIl1vgvI4iPWuElgE1i28gjr4oldlfBOYOxK/vcwuQIYwbpYDdL9mFsij/DRYs/UI2hpa0AmhNKfpaTjqr4XeaaHTtH6uK5x/tdiMflhPNEiN5V+O/Jc34KaK5toBTtZR5Lo4QJOlTEbhSlwyjqbBnvDoYGXnt6RyTJKqVWndlsfIdQT22yy5YzLG2D4tGBmvZHmbxjafTMcydkwgrw4LS+iXvBggNRkE12h0gChDtOc7L8UA7K6sH9tmlcAZ5warz7KnBAtCt5g8YMIyScBLs2epyKkuTf
          ehu@law.virginia.edu,eddyhu@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJNwhHJtvb4jpqCkKWwiOGva43GS4UMqP5ZVSrpdiOvsAAAAB3NzaDpuZmM=
          ehu@law.virginia.edu,eddyhu@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFypmbJQSsaLhmyhiBS6o1G3VGFr/JPmiiFR77sudJLPAAAACHNzaDpuYW5v
        '';
      };

      # Set agenix secret paths for GUI apps via launchd
      # (home.sessionVariables only works for shell sessions)
      launchd.agents.set-agenix-env = {
        enable = true;
        config = {
          Label = "com.user.set-agenix-env";
          ProgramArguments = [
            "/bin/bash"
            "-c"
            ''
              AGENIX_DIR="$(getconf DARWIN_USER_TEMP_DIR)agenix"
              launchctl setenv GOOGLE_SEARCH_API_KEY_FILE "$AGENIX_DIR/google-search-api-key"
              launchctl setenv GOOGLE_SEARCH_ENGINE_ID_FILE "$AGENIX_DIR/google-search-engine-id"
              launchctl setenv GEMINI_API_KEY_FILE "$AGENIX_DIR/gemini-api-key"
              launchctl setenv CLAUDE_API_KEY_FILE "$AGENIX_DIR/claude-api-key"
              launchctl setenv READWISE_TOKEN_FILE "$AGENIX_DIR/readwise-token"
              launchctl setenv RAINDROP_TOKEN_FILE "$AGENIX_DIR/raindrop-token"
              launchctl setenv WEBHOOK_SECRET_FILE "$AGENIX_DIR/webhook-secret"
              launchctl setenv QUALTRICS_API_TOKEN_FILE "$AGENIX_DIR/qualtrics-api-token"
              launchctl setenv GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND file
              launchctl setenv COMPANION_FORCE_BYPASS_IN_CONTAINER 1
            ''
          ];
          RunAtLoad = true;
        };
      };
      # Faithful docx->PDF via real Word in a QEMU Win11 ARM guest (see
      # ../shared/word-render/README.md for one-time guest setup). Portable:
      # the same config drives a Win11 x64 + KVM guest on a Linux host later.
      programs = { wordRender.enable = true; }
        // import ../shared/home-manager.nix { inherit pkgs lib user userInfo; };
    };
    extraSpecialArgs = { inherit user userInfo nix-secrets agenix; };
  };

}
