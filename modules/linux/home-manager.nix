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

  # Linux-specific program configurations
  programs = {
    # Enable bash as a fallback
    bash = {
      enable = true;
      enableCompletion = true;
      profileExtra = ''
        # PATH and nix profile sourcing is now handled in dotfiles/.shell_env
      '';
      
      bashrcExtra = ''
        # Suppress groups command warnings (must be early to catch /etc/bash.bashrc)
        groups() {
          command groups "$@" 2>/dev/null
        }

        # Aliases are now sourced from dotfiles/.shell_aliases via .shell_common
      '';

      initExtra = ''
        # Source shared shell configuration
        if [[ -f "$HOME/dotfiles/.shell_common" ]]; then
            source "$HOME/dotfiles/.shell_common"
        fi

        # Auto-start zsh if it exists and we're in an interactive session
        if [[ -x "$(command -v zsh)" ]] && [[ $- == *i* ]] && [[ ! "$SHELL" == *zsh* ]]; then
          export SHELL="$(command -v zsh)"
          exec -l zsh
        fi
      '';
    };
  } // import ../shared/home-manager.nix { inherit config pkgs lib user userInfo; };

  # Linux-specific services
  services = {
    # Add Linux-specific services here
  };
}