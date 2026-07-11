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
    users.${user} = { pkgs, lib, config, ... }: {
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
            'export CDP_PORT=$PORT' \
            'exec "$HOME/projects/superhuman-cli/dist/superhuman-darwin" "$@"' \
            > "$HOME/.local/bin/superhuman"
          $DRY_RUN_CMD chmod +x "$HOME/.local/bin/superhuman"
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
