{ config, lib, pkgs, user, ... }:

with lib;

let
  cfg = config.programs.sketchybar;
in {
  options.programs.sketchybar = {
    enable = mkEnableOption "Sketchybar status bar";

    package = mkOption {
      type = types.package;
      default = pkgs.sketchybar;
      description = "The sketchybar package to use";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages to make available to sketchybar scripts";
    };
  };

  config = mkIf cfg.enable {
    # Install sketchybar and related packages
    environment.systemPackages = with pkgs; [
      cfg.package
      lua
      jq  # Often used in sketchybar scripts
    ] ++ cfg.extraPackages;

    # Use existing nix-darwin service
    services.sketchybar = {
      enable = true;
      package = cfg.package;
    };

    # Config is managed via dotfiles (~/.config/sketchybar)
  };
}
