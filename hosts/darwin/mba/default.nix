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

  # Configure system-level zsh to source local user overrides
  programs.zsh = {
    enable = true;
    interactiveShellInit = ''
      # Source local user overrides from ~/.zshrc.local
      # This allows users to add custom PATH entries and other config
      # without modifying nix-managed files
      if [[ -f "$HOME/.zshrc.local" ]]; then
        source "$HOME/.zshrc.local"
      fi
    '';
  };

}
