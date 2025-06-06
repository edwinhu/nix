{ config, pkgs, ... }:

let user = "edwinhu"; in

{

  imports = [
    ../../modules/darwin/home-manager.nix
    ../../modules/shared
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
  ] ++ (import ../../modules/shared/packages.nix { inherit pkgs; });

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

        # 120, 90, 60, 30, 12, 6, 2
        KeyRepeat = 2;

        # 120, 94, 68, 35, 25, 15
        InitialKeyRepeat = 15;

        "com.apple.mouse.tapBehavior" = 1;
        "com.apple.sound.beep.volume" = 0.0;
        "com.apple.sound.beep.feedback" = 0;
      };

      dock = {
        autohide = true;
        show-recents = false;
        launchanim = true;
        orientation = "bottom";
        tilesize = 48;
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
}
