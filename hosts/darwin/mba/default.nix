{ config, pkgs, user, userInfo, ... }:

{
  imports = [
    ../../../modules/shared
    ../../../modules/darwin/home-manager.nix
    ../../../modules/darwin/aerospace.nix
    ../../../modules/darwin/sketchybar
    ../../../modules/darwin/defaults.nix
  ];

  # Reminder for terminal app permissions
  system.activationScripts.checkTerminalPermissions.text = ''
    echo "⚠️  Remember to grant Full Disk Access to terminal apps in System Settings"
    echo "   Privacy & Security → Full Disk Access → Add Ghostty & WezTerm"
    echo "   This is required for zellij and other terminal tools to work properly"
  '';

  # Add system-level zsh configuration to source .zshrc.local
  programs.zsh.interactiveShellInit = ''
    # Source local user overrides
    if [[ -f "$HOME/.zshrc.local" ]]; then
      source "$HOME/.zshrc.local"
    fi
  '';

}
