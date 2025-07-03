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
    };
  } // import ../shared/home-manager.nix { inherit config pkgs lib user userInfo; };

  # Linux-specific services
  services = {
    # Add Linux-specific services here
  };
}