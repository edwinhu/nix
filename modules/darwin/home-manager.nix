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
    masApps = {
      "bear" = 1091189122;
      "microsoft to-do" = 1274495053;
      # "amazon kindle" = 302584613;  # Temporarily disabled - Mac App Store install failing
      "microsoft word" = 462054704;
      "microsoft excel" = 462058435;
      # "microsoft powerpoint" = 462062816;  # Temporarily disabled - brew bundle `mas get` fails on mas 2.3.0
      "joystick mapper" = 528183797;
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
      ];

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

        # Idempotent bootstrap for AI CLIs (claude, codex, opencode, the-companion).
        # Each tool self-updates after install, so this only runs missing installs.
        # Use `nix run ~/nix#update-ai-tools` to force-bump to latest.
        # PATH must include curl (installer downloads) plus user dirs so `want()`
        # sees already-installed tools and skips reinstall.
        activation.installAITools = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD env \
            PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.opencode/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
            ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh || true
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
              launchctl setenv QUALTRICS_API_TOKEN_FILE "$AGENIX_DIR/qualtrics-api-token"
              launchctl setenv COMPANION_FORCE_BYPASS_IN_CONTAINER 1
            ''
          ];
          RunAtLoad = true;
        };
      };
      programs = {} // import ../shared/home-manager.nix { inherit pkgs lib user userInfo; };
    };
    extraSpecialArgs = { inherit user userInfo nix-secrets agenix; };
  };

}
