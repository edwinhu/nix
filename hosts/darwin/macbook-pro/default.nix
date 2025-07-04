{ config, pkgs, user, userInfo, ... }:

{

  imports = [
    ../../../modules/shared
    ../../../modules/shared/secrets.nix
    ../../../modules/darwin/home-manager.nix
    ../../../modules/darwin/aerospace.nix
  ];

  # Auto upgrade nix package and the daemon service.
  # services.nix-daemon.enable = true;

  # Setup user, packages, programs
  nix = {
    package = pkgs.nix;
    settings = {
      trusted-users = [ "@admin" "${user}" ];
      substituters = [ "https://nix-community.cachix.org" "https://cache.nixos.org" ];
      trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    };

    extraOptions = ''
      experimental-features = nix-command flakes
    '';  
  };

  # Turn off NIX_PATH warnings now that we're using flakes
  system.checks.verifyNixPath = false;

  # Load configuration that is shared across systems
  environment.systemPackages = with pkgs; [
  ] ++ (import ../../../modules/shared/packages.nix { inherit pkgs; });


  system = {
    stateVersion = 4;
    # 2025-01-30
    # - Previously, some nix-darwin options applied to the user running
    #   `darwin-rebuild`. As part of a long‐term migration to make
    #   nix-darwin focus on system‐wide activation and support first‐class
    #   multi‐user setups, all system activation now runs as `root`, and
    #   these options instead apply to the `system.primaryUser` user.
    primaryUser = user;

    defaults = {
      NSGlobalDomain = {
        AppleShowAllExtensions = true;
        ApplePressAndHoldEnabled = false;
        # Automatically hide and show the menu bar
        _HIHideMenuBar = true;
        # Disable window animations
        NSAutomaticWindowAnimationsEnabled = false;

        # 120, 90, 60, 30, 12, 6, 2
        KeyRepeat = 2;

        # 120, 94, 68, 35, 25, 15
        InitialKeyRepeat = 15;

        "com.apple.mouse.tapBehavior" = 1;
        "com.apple.sound.beep.volume" = 0.0;
        "com.apple.sound.beep.feedback" = 0;
        "com.apple.trackpad.scaling" = 3.0;
      };

      dock = {
        autohide = true;
        show-recents = false;
        launchanim = true;
        orientation = "bottom";
        tilesize = 48;
        persistent-apps = [
          "/Applications/WezTerm.app/"
          "/Applications/Dia.app/"
          "/Applications/Morgen.app/"
          "/Applications/Visual Studio Code.app/"
          "/Applications/Logseq.app/"
          "/Applications/Obsidian.app/"
          "/Applications/Bitwarden.app/"
          "/Applications/Beeper Desktop.app/"
        ];
        persistent-others = [
          "${config.users.users.${user}.home}/Downloads"
        ];
      };

      finder = {
        _FXShowPosixPathInTitle = false;
      };

      trackpad = {
        Clicking = true;
        TrackpadThreeFingerDrag = true;
      };
    };
  };

  # Enable Touch ID authentication for sudo
  security.pam.services.sudo_local.touchIdAuth = true;

  services.sketchybar = {
    enable = true;
    package = pkgs.sketchybar;
  };

  services.emacs.enable = true;

}