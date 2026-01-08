{ config, pkgs, lib, home-manager, homebrew-emacport, stylix, agenix, user, userInfo, nix-secrets, ... }:

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
      upgrade = true;
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
      "microsoft to-do" = 1274495053;
      # "amazon kindle" = 302584613;  # Temporarily disabled - Mac App Store install failing
      "microsoft word" = 462054704;
      "microsoft excel" = 462058435;
      "microsoft powerpoint" = 462062816;
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
        file.".local/bin/claude" = {
          source = "${pkgs.claude-code}/bin/claude";
          force = true;
        };
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
