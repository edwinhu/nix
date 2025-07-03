{ config, pkgs, lib, user, userInfo, ... }:

{
  imports = [
    ../../users/${user}
  ];

  # Linux-specific configurations
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    
    # Linux-specific packages
    packages = with pkgs; [
      # Add Linux-specific packages here
      xclip
      xdg-utils
    ] ++ (import ../shared/packages.nix { inherit pkgs; });
    
    sessionVariables = {
      # Add Linux-specific environment variables
      SHELL = "${pkgs.zsh}/bin/zsh";
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
      initExtra = ''
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