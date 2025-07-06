{ config, lib, pkgs, user, ... }:

with lib;

let
  cfg = config.programs.sketchybar;
  
  # Check if sbarlua is available in nixpkgs
  sbarlua = pkgs.sbarlua or null;
  
  homeDir = config.users.users.${user}.home;
  
  # Create the sketchybarrc script
  sketchybarrc = pkgs.writeScript "sketchybarrc" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ./sketchybarrc}
  '';
  
  # Script to set up configuration files
  setupScript = pkgs.writeScriptBin "setup-sketchybar" ''
    #!${pkgs.bash}/bin/bash
    
    CONFIG_DIR="${homeDir}/.config/sketchybar"
    
    # Create directories
    mkdir -p "$CONFIG_DIR/items" "$CONFIG_DIR/helpers"
    
    # Copy configuration files
    cp "${sketchybarrc}" "$CONFIG_DIR/sketchybarrc"
    chmod +x "$CONFIG_DIR/sketchybarrc"
    
    # Copy item scripts
    cp ${./items}/*.sh "$CONFIG_DIR/items/"
    chmod +x "$CONFIG_DIR/items/"*.sh
    
    # Copy helpers if any
    if [ -d "${./helpers}" ]; then
      cp ${./helpers}/* "$CONFIG_DIR/helpers/" 2>/dev/null || true
      chmod +x "$CONFIG_DIR/helpers/"* 2>/dev/null || true
    fi
    
    # Reload sketchybar if running
    ${cfg.package}/bin/sketchybar --reload 2>/dev/null || true
  '';
  
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
      setupScript
    ] ++ cfg.extraPackages ++ (optional (sbarlua != null) sbarlua);
    
    # Use existing nix-darwin service
    services.sketchybar = {
      enable = true;
      package = cfg.package;
    };
    
    # Set up configuration on activation
    system.activationScripts.sketchybar.text = ''
      echo "Setting up sketchybar configuration..."
      sudo -u ${user} ${setupScript}/bin/setup-sketchybar
    '';
  };
}