{ config, pkgs, user, userInfo, ... }:

{
  imports = [
    ./dock
  ];

  # Nix configuration
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

  # Load shared packages
  environment.systemPackages = with pkgs; [
  ] ++ (import ../shared/packages.nix { inherit pkgs; });

  system = {
    stateVersion = 4;
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
      };

      finder = {
        _FXShowPosixPathInTitle = false;
      };

      trackpad = {
        Clicking = true;
        TrackpadThreeFingerDrag = true;
      };

      # Mission Control settings
      spaces = {
        # Disable "Displays have separate Spaces" for aerospace compatibility
        spans-displays = false;
      };
    };
  };

  # Enable Touch ID authentication for sudo
  security.pam.services.sudo_local.touchIdAuth = true;

  # Sketchybar configuration
  programs.sketchybar = {
    enable = true;
    package = pkgs.sketchybar;
  };

  # Emacs service
  services.emacs.enable = true;

  # Declarative dock configuration shared across all Darwin systems
  local.dock = {
    enable = true;
    username = user;
    entries = [
      { path = "/Applications/Ghostty.app"; }
      { path = "/Applications/Superhuman.app"; }
      { path = "/Applications/Reader.app"; }
      { path = "/Applications/Dia.app"; }
      { path = "/Applications/Morgen.app"; }
      { path = "/Applications/Visual Studio Code.app"; }
      { path = "/Applications/Logseq.app"; }
      { path = "/Applications/Obsidian.app"; }
      { path = "/Applications/Bitwarden.app"; }
      { path = "/Applications/Beeper Desktop.app"; }
      {
        path = "${config.users.users.${user}.home}/Downloads";
        section = "others";
        options = "--view list --display stack --sort datemodified";
      }
    ];
  };
}