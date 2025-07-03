{ config, pkgs, lib, ... }:

{
  # User-specific configuration for vwh7mb
  # This is imported by home-manager modules
  
  config = {
    # Personal information
    programs.git = {
      userName = "Edwin Hu";
      userEmail = "eddyhu@gmail.com";
    };

    # SSH configuration
    programs.ssh.matchBlocks = {
      "github.com" = {
        identitiesOnly = true;
        identityFile = [
          "${config.home.homeDirectory}/.ssh/id_github"
        ];
      };
    };

    # User-specific packages
    home.packages = with pkgs; [
      # Add any vwh7mb-specific packages here
    ];

    # User-specific shell aliases or configurations
    programs.zsh.initContent = lib.mkBefore ''
      # vwh7mb-specific shell configurations
    '';
  };
}