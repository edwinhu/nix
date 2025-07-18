{ config, pkgs, lib, user, userInfo, ... }:

{
  imports = [
    ../../../modules/linux/home-manager.nix
    ../../../modules/shared/home-secrets.nix
  ];

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";
  };

  # Enable basic programs
  programs.home-manager.enable = true;
}