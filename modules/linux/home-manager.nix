{ self, config, pkgs, lib, user, userInfo, agenix, ... }:

{
  imports = [
    ../shared/stylix.nix
    ./the-companion.nix
  ];

  # Linux-specific Stylix configuration (Qt theming)
  stylix.targets.qt = {
    enable = true;
    platform = "qtct";
  };

  # Linux-specific configurations
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    
    # Linux-specific packages
    packages = with pkgs; [
      # Add Linux-specific packages here
      xdg-utils
      inotify-tools
      imagemagick
      libreoffice  # Headless spreadsheet recalculation via soffice --headless
      agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
      # Qt configuration tools for Stylix
      libsForQt5.qt5ct
      kdePackages.qt6ct
      libsForQt5.qtstyleplugin-kvantum
      kdePackages.qtstyleplugin-kvantum
    ] ++ (import ../shared/packages.nix { inherit pkgs; });
    
    sessionVariables = {
      # Add Linux-specific environment variables
      SHELL = "${pkgs.zsh}/bin/zsh";
      EDITOR = "nvim";
      VISUAL = "nvim";
      ALTERNATE_EDITOR = "";
    };

    # rv (R package manager) - install from official installer if not present
    activation.rv = lib.hm.dag.entryAfter ["writeBoundary"] ''
      RV_BIN="$HOME/.local/bin/rv"
      if [ ! -x "$RV_BIN" ]; then
        $DRY_RUN_CMD mkdir -p "$HOME/.local/bin"
        $DRY_RUN_CMD ${pkgs.curl}/bin/curl -LsSf https://a2-ai.github.io/rv-docs/install.sh | $DRY_RUN_CMD ${pkgs.bash}/bin/bash -s -- --to "$HOME/.local/bin"
      fi
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
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts for Linux
  fonts.fontconfig.enable = true;

  # Program configurations - shell config managed by dotfiles
  programs = import ../shared/home-manager.nix { inherit config pkgs lib user userInfo; };

  # Linux-specific services
  services = {
    # Syncthing - continuous file synchronization
    syncthing = {
      enable = true;
      tray.enable = false;  # No system tray on headless systems
    };
  };
}