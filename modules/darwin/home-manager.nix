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
          # Superhuman wrapper with CDP tab auto-open fallback
          $DRY_RUN_CMD rm -f "$HOME/.local/bin/superhuman"
          printf '%s\n' \
            '#!/bin/bash' \
            'CDP_URL="http://localhost:9250"' \
            'if curl -s --max-time 2 "$CDP_URL/json/version" >/dev/null 2>&1; then' \
            '  if ! curl -s --max-time 2 "$CDP_URL/json/list" 2>/dev/null | python3 -c "import json,sys; targets=json.load(sys.stdin); exit(0 if any(t['"'"'type'"'"']=='"'"'page'"'"' and '"'"'mail.superhuman.com'"'"' in t['"'"'url'"'"'] and '"'"'background'"'"' not in t['"'"'url'"'"'] for t in targets) else 1)" 2>/dev/null; then' \
            '    curl -s --max-time 5 -X PUT "$CDP_URL/json/new?https://mail.superhuman.com" >/dev/null 2>&1' \
            '    sleep 4' \
            '  fi' \
            'fi' \
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
        # Both emails (work + personal) trust both YubiKey signing pubkeys.
        file.".config/git/allowed_signers".text = ''
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
