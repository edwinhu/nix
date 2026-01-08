# Omarchy (Arch Linux on Asahi) desktop configuration
# Minimal nix config - dotfiles managed separately
{ config, pkgs, lib, user, userInfo, ... }:

let
  iconDir = ../../../modules/linux/desktop-icons;
in
{
  imports = [
    ../../../modules/shared/home-secrets.nix
  ];

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";

    # Cherry-picked packages not in Omarchy/pacman
    packages = (import ../../../modules/linux/omarchy-packages.nix { inherit pkgs; }) ++ [
      pkgs.zathura  # Custom fork with annotations
    ];

    # Install desktop entry icons
    file.".local/share/applications/icons/OpenCode.svg".source = "${iconDir}/Docker.svg";  # Placeholder until we have OpenCode icon
    file.".local/share/applications/icons/Docker.svg".source = "${iconDir}/Docker.svg";
    file.".local/share/applications/icons/Morgen.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Beeper.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon  
    file.".local/share/applications/icons/Superhuman.svg".source = "${iconDir}/Superhuman.svg";
    file.".local/share/applications/icons/Tailscale.svg".source = "${iconDir}/Tailscale.svg";
    file.".local/share/applications/icons/Tailscale Admin Console.png".source = "${iconDir}/Tailscale Admin Console.png";
    file.".local/share/applications/icons/YouTube Music.png".source = "${iconDir}/YouTube Music.png";
    file.".local/share/applications/icons/Strem.io.svg".source = "${iconDir}/Strem.io.svg";
    file.".local/share/applications/icons/Readwise Reader.png".source = "${iconDir}/Readwise Reader.png";
    file.".local/share/applications/icons/Calculator.svg".source = "${iconDir}/Calculator.svg";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts
  fonts.fontconfig.enable = true;

  # Enable home-manager
  programs.home-manager.enable = true;

  # Desktop entries - only the custom ones not provided by Omarchy
  xdg.desktopEntries = {
    opencode = {
      name = "OpenCode";
      comment = "The open source AI coding agent";
      exec = "${pkgs.opencode}/bin/opencode";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/OpenCode.svg";
      categories = [ "Development" "IDE" ];
      startupNotify = true;
    };

    docker = {
      name = "Docker";
      comment = "Docker container management";
      exec = "xdg-terminal-exec --app-id=TUI.tile -e lazydocker";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Docker.svg";
      startupNotify = true;
    };

    morgen = {
      name = "Morgen";
      comment = "Calendar and Tasks";
      exec = "/home/${user}/.local/opt/Morgen/morgen %U";
      terminal = false;
      type = "Application";
      icon = "morgen";
      categories = [ "Utility" ];
      mimeType = [ "text/calendar" "x-scheme-handler/morgen" ];
    };

    beeper = {
      name = "Beeper";
      comment = "Beeper messaging app";
      exec = "/home/${user}/.local/share/applications/appimages/Beeper.AppImage --no-sandbox %U";
      terminal = false;
      type = "Application";
      icon = "beeper";
      categories = [ "Network" ];
      mimeType = [ "x-scheme-handler/beeper" ];
    };

    superhuman = {
      name = "Superhuman";
      comment = "Superhuman email client";
      exec = "/usr/bin/chromium --profile-directory=Default --app-id=cabkgbgkeonbpeoedbaeolhgfkempoka";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Superhuman.svg";
      startupNotify = true;
    };

    tailscale = {
      name = "Tailscale";
      comment = "Tailscale VPN";
      exec = "xdg-terminal-exec --app-id=TUI.float -e sudo tsui";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale.svg";
      startupNotify = true;
    };

    tailscale-admin = {
      name = "Tailscale Admin Console";
      comment = "Tailscale Admin Console";
      exec = "omarchy-launch-webapp https://login.tailscale.com/admin/machines";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale Admin Console.png";
      startupNotify = true;
    };

    youtube-music = {
      name = "YouTube Music";
      comment = "YouTube Music";
      exec = "omarchy-launch-webapp https://music.youtube.com";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/YouTube Music.png";
      startupNotify = true;
    };

    stremio = {
      name = "Strem.io";
      comment = "Strem.io streaming";
      exec = "omarchy-launch-webapp https://web.strem.io/";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Strem.io.svg";
      startupNotify = true;
    };

    readwise-reader = {
      name = "Readwise Reader";
      comment = "Readwise Reader";
      exec = "omarchy-launch-webapp https://read.readwise.io/";
      terminal = false;
      type = "Application";
      icon = "readwise-reader";
      startupNotify = true;
    };

    calculator = {
      name = "Calculator (Numr)";
      comment = "Numr - vim-style calculator";
      exec = "xdg-terminal-exec --app-id=TUI.tile -e ${pkgs.numr}/bin/numr";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Calculator.svg";
      startupNotify = true;
    };

    zathura = {
      name = "Zathura";
      comment = "Document viewer";
      exec = "${pkgs.zathura}/bin/zathura %U";
      terminal = false;
      type = "Application";
      icon = "org.pwmt.zathura";
      categories = [ "Office" "Viewer" ];
      mimeType = [ "application/pdf" "application/epub+zip" "image/vnd.djvu" ];
    };
  };
}
