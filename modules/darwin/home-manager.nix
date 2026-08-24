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
        # agents here (macOS) and systemd user services on Linux. Imported but
        # NOTHING is enabled on this Mac — see below.
        ../shared/reader-services.nix
      ];

      # NO always-on browser/CDP services on this laptop. This is no longer the
      # primary machine, and every one of these agents was a battery tax: a
      # resident Chrome under KeepAlive plus watchdog timers firing every 2 min
      # and an SSO warmup every 25 min, forever, on a machine that is usually
      # closed. omarchy is the always-on primary and already runs the whole set
      # — chrome-cdp + watchdog, the readwise webhook + sweep, and Morgen as a
      # Hyprland webapp on :9222 — so nothing is lost by turning them off here,
      # only duplicated work removed. Retired at the same time:
      #   readerServices.enableChromeCdp   (com.chrome-cdp, resident Chrome :9250)
      #   activation.installChromeCdp      (com.chrome-cdp-watchdog, 120s)
      #   launchd.agents.dia-cdp           (Dia on :9222 at login)
      #   launchd.agents.dia-cdp-watchdog  (120s probe + Dia restart)
      #   activation.installDiaCdpApp      ("Dia (CDP).app" wrapper bundle)
      # plus the hand-placed com.user.morgen-cdp and com.paperpile.warmup
      # plists, deleted from ~/Library/LaunchAgents.
      #
      # Consequence, by design: browser automation, paper-fetch, and the morgen
      # CLI no longer have a browser waiting for them here. To bring any of this
      # back, prefer running it on omarchy.

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
        # ~/.local/bin must exist before the *-update apps and the AI-tool
        # stubs below write into it.
        activation.linkLocalBin = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD mkdir -p "$HOME/.local/bin"
        '';


        # Idempotent bootstrap for the AI CLIs: writes mise stubs into
        # ~/.local/bin. Each stub re-resolves its tool on run, so this never
        # pins a version; `nix run ~/nix#update-ai-tools` forces a bump past
        # mise's release cooldown. mise must be on PATH explicitly — the
        # activation PATH doesn't include the nix profile.
        activation.installAITools = lib.hm.dag.entryAfter ["writeBoundary"] ''
          # Not a silent `|| true`: this installs the ~/.local/bin stubs the
          # launchd scheduled tasks launch through, so a network/rate-limit
          # failure here surfaces much later as a job that cannot exec, with
          # nothing tying it back to the switch that broke it.
          if ! $DRY_RUN_CMD env \
            PATH="$HOME/.local/bin:$HOME/.bun/bin:${pkgs.mise}/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
            ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh; then
            echo "WARNING: setup-ai-tools.sh failed — AI CLI stubs in ~/.local/bin may be missing or stale" >&2
          fi
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
            echo "WARNING: claude-stable: $CLAUDE_LINK not present — scheduled tasks that launch through claude-stable will fail to exec (install claude, then re-run build-switch)" >&2
          fi
        '');

        # ~/.local/log must exist even with the always-on CDP services retired:
        # paperpile-readwise and the scheduled tasks write there, and launchd
        # cannot set up a job's stdio into a missing directory — the job then
        # fails to start with the reason going nowhere.
        activation.ensureLocalDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD mkdir -p "$HOME/.local/bin" "$HOME/.local/log"
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
