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

  # Add ~/.local/bin to PATH via environment
  # Note: user's .zshrc may override this, so we also source .zshrc.local
  environment.variables = {
    # Prepend to PATH - but this gets set early and may be overridden
  };

  programs.zsh = {
    enable = true;
    # This runs after user's .zshrc via the prompt initialization
    promptInit = ''
      # Final PATH adjustment to ensure ~/.local/bin is first
      if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
      fi
    '';
    interactiveShellInit = ''
      # Source local user overrides early
      if [[ -f "$HOME/.zshrc.local" ]]; then
        source "$HOME/.zshrc.local"
      fi
    '';
  };

}
