{ config, pkgs, user, userInfo, ... }:

{

  imports = [
    ../../../modules/shared
    ../../../modules/darwin/home-manager.nix
    ../../../modules/darwin/aerospace.nix
    ../../../modules/darwin/sketchybar
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

  # Sketchybar is now configured through the new module
  programs.sketchybar = {
    enable = true;
    package = pkgs.sketchybar;
  };

  services.emacs.enable = true;

  # Reminder for terminal app permissions
  system.activationScripts.checkTerminalPermissions.text = ''
    echo "⚠️  Remember to grant Full Disk Access to terminal apps in System Settings"
    echo "   Privacy & Security → Full Disk Access → Add Ghostty & WezTerm"
    echo "   This is required for zellij and other terminal tools to work properly"
  '';

  # Configure SSH daemon on port 420
  system.activationScripts.sshPort420.text = ''
    echo "Configuring SSH daemon on port 420..."

    # Create SSH config for port 420 based on the system default
    if [ -f /etc/ssh/sshd_config.before-nix-darwin ]; then
      cp /etc/ssh/sshd_config.before-nix-darwin /tmp/sshd_config_420

      # Update port configuration - handle both commented and uncommented port lines
      sed -i "" "s/#Port 22/Port 420/" /tmp/sshd_config_420
      sed -i "" "s/^Port 22/Port 420/" /tmp/sshd_config_420

      # Add port 420 if no port line exists
      if ! grep -q "^Port" /tmp/sshd_config_420; then
        sed -i "" "1i\\
Port 420
" /tmp/sshd_config_420
      fi

      # Disable password authentication
      sed -i "" "s/#PasswordAuthentication yes/PasswordAuthentication no/" /tmp/sshd_config_420
      sed -i "" "s/^PasswordAuthentication yes/PasswordAuthentication no/" /tmp/sshd_config_420

      # Ensure root login is disabled
      sed -i "" "s/#PermitRootLogin prohibit-password/PermitRootLogin no/" /tmp/sshd_config_420
      sed -i "" "s/^PermitRootLogin.*/PermitRootLogin no/" /tmp/sshd_config_420

      # Kill any existing SSH daemon on port 420
      pkill -f "sshd.*-f /tmp/sshd_config_420" 2>/dev/null || true
      sleep 1

      # Test configuration before starting
      if /usr/sbin/sshd -t -f /tmp/sshd_config_420 2>/dev/null; then
        # Start SSH daemon on port 420
        /usr/sbin/sshd -f /tmp/sshd_config_420
        echo "SSH daemon started on port 420"

        # Verify it's listening
        sleep 2
        if lsof -i :420 >/dev/null 2>&1; then
          echo "Confirmed: SSH is listening on port 420"
        else
          echo "Warning: SSH may not be listening on port 420"
        fi
      else
        echo "Error: SSH configuration test failed for port 420"
      fi
    else
      echo "Error: SSH config backup not found at /etc/ssh/sshd_config.before-nix-darwin"
    fi
  '';

}