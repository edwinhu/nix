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

      # Custom preferences not covered by nix-darwin options
      CustomUserPreferences = {
        NSGlobalDomain = {
          # Set ForkLift as default file viewer
          NSFileViewer = "com.binarynights.ForkLift";
        };
      };
    };

    # Set default app handlers (idempotent activation script)
    activationScripts.postActivation.text = ''
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
    '';
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
      { path = "/Applications/Nix Apps/WezTerm.app"; }
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
        options = "--view auto --display stack --sort datemodified";
      }
    ];
  };
}