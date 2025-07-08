{ config, pkgs, lib, user, userInfo, ... }:

{
  imports = [
    ../../../modules/linux/home-manager.nix
  ];

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";
    
    # Override packages with minimal set
    packages = lib.mkForce ((import ../../../modules/shared/packages-minimal.nix { inherit pkgs; }) ++ [
      # No additional Linux-specific packages needed for minimal setup
    ]);
  };

  # Enable basic programs
  programs.home-manager.enable = true;
}