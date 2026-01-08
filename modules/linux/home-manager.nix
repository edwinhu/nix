{ config, pkgs, lib, user, userInfo, agenix, ... }:

{
  imports = [
    ../shared/stylix.nix
  ];

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
      agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
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

    file.".local/bin/claude" = {
      source = "${pkgs.claude-code}/bin/claude";
    };
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts for Linux
  fonts.fontconfig.enable = true;

  # Program configurations - shell config managed by dotfiles
  programs = import ../shared/home-manager.nix { inherit config pkgs lib user userInfo; };

  # Linux-specific services
  services = {
    # Add Linux-specific services here
  };
}