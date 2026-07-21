{ config, lib, pkgs, user, userInfo, ... }:

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

  # Weekly nix store GC + optimise (Determinate Nix manages the daemon, so
  # nix-darwin's nix.gc/nix.optimise are disabled — use launchd directly).
  launchd.daemons.nix-gc = {
    serviceConfig = {
      Label = "org.nixos.nix-gc";
      ProgramArguments = [
        "/bin/sh" "-c"
        "/nix/var/nix/profiles/default/bin/nix-collect-garbage --delete-older-than 30d"
      ];
      StartCalendarInterval = [ { Weekday = 0; Hour = 4; Minute = 0; } ];
      StandardOutPath = "/var/log/nix-gc.log";
      StandardErrorPath = "/var/log/nix-gc.log";
    };
  };

  launchd.daemons.nix-optimise = {
    serviceConfig = {
      Label = "org.nixos.nix-optimise";
      ProgramArguments = [
        "/bin/sh" "-c"
        "/nix/var/nix/profiles/default/bin/nix-store --optimise"
      ];
      StartCalendarInterval = [ { Weekday = 0; Hour = 5; Minute = 0; } ];
      StandardOutPath = "/var/log/nix-optimise.log";
      StandardErrorPath = "/var/log/nix-optimise.log";
    };
  };

  # Turn off NIX_PATH warnings now that we're using flakes
  system.checks.verifyNixPath = false;

  # Load darwin packages (includes shared)
  environment.systemPackages = import ./packages.nix { inherit pkgs; };

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
        # Disable "Displays have separate Spaces" for aerospace compatibility.
        # spans-displays = true means a single Space spans all displays, which
        # is the inverse of the macOS checkbox being on.
        spans-displays = true;
      };

      # Custom preferences not covered by nix-darwin options
      CustomUserPreferences = {
        NSGlobalDomain = {
          # Set ForkLift as default file viewer
          NSFileViewer = "com.binarynights.ForkLift";
        };
      };
    };

    # Set default app handlers and copy nix apps (idempotent activation script)
    # Copy must happen in postActivation so /Applications/Nix Apps/ is already populated.
    activationScripts.postActivation.text = ''
      # Copy nix .apps that need macOS TCC permissions to /Applications
      # so permissions persist across nix rebuilds (TCC ties to binary path,
      # and /Applications/Nix Apps/ gets recreated on every rebuild).
      echo "Copying nix apps to /Applications (stable paths for TCC permissions)..."
      if [ -e "/Applications/Nix Apps/WezTerm.app" ]; then
        rm -rf "/Applications/WezTerm.app"
        cp -RL "/Applications/Nix Apps/WezTerm.app" "/Applications/WezTerm.app"
        chmod -R u+w "/Applications/WezTerm.app"
        echo "  Copied WezTerm.app"
      fi

      # Web-app wrappers built outside the Nix Apps tree (not in environment.systemPackages).
      # Copied directly from their derivation outputs so /Applications/<App>.app is
      # always in sync with the current build.
      rm -rf "/Applications/OmniWM.app"
      cp -RL "${pkgs.omniwm}/Applications/OmniWM.app" "/Applications/OmniWM.app"
      chmod -R u+w "/Applications/OmniWM.app"
      echo "  Copied OmniWM.app"
      # Disable Karabiner-Elements' built-in Sparkle auto-updater.
      # Every auto-update replaces the .app and DriverKit extension, which
      # forces re-approval of Input Monitoring, Accessibility, and the DEXT.
      # Combined with homebrew `upgrade = false`, this pins the installed
      # version until the user explicitly runs `brew upgrade karabiner-elements`.
      for bundle in org.pqrs.Karabiner-Elements org.pqrs.Karabiner-EventViewer org.pqrs.Karabiner-Elements.Settings; do
        sudo -u ${user} defaults write "$bundle" SUEnableAutomaticChecks -bool false 2>/dev/null || true
        sudo -u ${user} defaults write "$bundle" SUAutomaticallyUpdate -bool false 2>/dev/null || true
      done

      # ForkLift as default folder handler
      if ! sudo -u ${user} defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | grep -q "com.binarynights.ForkLift"; then
        sudo -u ${user} defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers -array-add '{LSHandlerContentType="public.folder";LSHandlerRoleAll="com.binarynights.ForkLift";}'
      fi

      # Neovide as default text/code editor
      if ! sudo -u ${user} defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | grep -q "com.neovide.neovide"; then
        # UTI-based handlers
        for uti in public.plain-text public.text public.utf8-plain-text public.source-code public.shell-script public.python-script public.json public.xml net.daringfireball.markdown public.yaml public.toml public.data public.content public.ruby-script public.perl-script; do
          sudo -u ${user} defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers -array-add "{LSHandlerContentType=\"$uti\";LSHandlerRoleAll=\"com.neovide.neovide\";}"
        done
        # File extension-based handlers (covers Zed + VS Code defaults + extras)
        for ext in c c++ cc cpp cxx css erb ex exs go h h++ hh hpp hxx htm html js cjs mjs json jsx md markdown mdown mdwn mkd mkdn mdoc mdtext mdtxt py pyi rb rkt rs scm toml ts tsx txt nix vue svelte yaml yml eyaml eyml sh bash zsh fish lua zig hs el lisp clj cljs edn sql graphql prisma tf hcl dockerfile makefile cmake asp aspx cshtml jshtm jsp phtml shtml bat cmd bowerrc config editorconfig ini cfg gitattributes gitconfig gitignore m mm cs csx csproj dtd java jav gemspec jade less sass scss ps1 psd1 psm1 plist wxi wxl wxs xaml xhtml xml php; do
          sudo -u ${user} defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers -array-add "{LSHandlerContentTag=\"$ext\";LSHandlerContentTagClass=\"public.filename-extension\";LSHandlerRoleAll=\"com.neovide.neovide\";}"
        done
      fi

      # PIV smart card login: allow but never enforce (password/Touch ID fallback).
      # System-level `defaults write` can hang if cfprefsd is wedged, so keep
      # these writes idempotent and bounded.
      write_smartcard_default() {
        key="$1"
        expected="$2"
        current="$(${pkgs.coreutils}/bin/timeout 3s defaults read /Library/Preferences/com.apple.security.smartcard "$key" 2>/dev/null || true)"

        if [ "$current" = "$expected" ]; then
          return 0
        fi

        if ! ${pkgs.coreutils}/bin/timeout 5s defaults write /Library/Preferences/com.apple.security.smartcard "$key" -bool "$expected"; then
          echo "warning: timed out setting com.apple.security.smartcard $key=$expected; continuing" >&2
        fi
      }

      write_smartcard_default allowSmartCard true
      write_smartcard_default enforceSmartCard false
    '';
  };

  # sudo: Touch ID first, then YubiKey FIDO2 (reads ~/.config/Yubico/u2f_keys).
  # Both `sufficient`, so password remains the fallback.
  # Screen unlock uses PIV/smart card (screensaver_ctk), not FIDO2/PAM.
  security.pam.services.sudo_local = {
    touchIdAuth = true;
    text = lib.mkAfter
      "auth       sufficient     ${pkgs.pam_u2f}/lib/security/pam_u2f.so cue";
  };

  # Allow admin group members to use sudo without password
  security.sudo.extraConfig = ''
    %admin ALL=(ALL) NOPASSWD: ALL
  '';

  # Sketchybar configuration
  programs.sketchybar = {
    enable = true;
    package = pkgs.sketchybar;
  };

  # Declarative dock configuration shared across all Darwin systems
  local.dock = {
    enable = true;
    username = user;
    entries = [
      { path = "/Applications/cmux.app"; }
      { path = "/Applications/Superhuman.app"; }
      { path = "/Applications/Reader.app"; }
      # Wrapper bundle, NOT /Applications/Dia.app — clicking the real app
      # launches Dia without --remote-debugging-port, which then holds the
      # profile SingletonLock and leaves CDP 9222 permanently down. Built by
      # activation.installDiaCdpApp in home-manager.nix.
      { path = "${config.users.users.${user}.home}/Applications/Dia (CDP).app"; }
      { path = "/Applications/Morgen.app"; }
      { path = "/Applications/Visual Studio Code.app"; }
      { path = "/Applications/Obsidian.app"; }
      { path = "/Applications/1Password.app"; }
      { path = "/Applications/Beeper Desktop.app"; }
      {
        path = "${config.users.users.${user}.home}/Downloads";
        section = "others";
        options = "--view auto --display stack --sort datemodified";
      }
    ];
  };
}
