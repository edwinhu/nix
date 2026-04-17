_:

[
  # Development Tools
  "orbstack"
  "github"
  "cmux"
  "codex-app"
  "neovide-app"
  "visual-studio-code"
  # "wezterm"  # Removed: using nix package for version consistency across systems
  "zed"

  # Communication Tools
  "beeper"
  "granola"
  "macwhisper"
  "superhuman"
  "zoom"

  # Utility Tools
  "bitwarden"
  "blip"
  "karabiner-elements"
  # "claude"  # Managed by nix run .#claude-desktop-update (Homebrew cask lags behind)
  "homerow"
  # "morgen"  # Waiting for cask to update to 4.0.0 (currently 3.6.19)
  "obsidian"
  "paletro"
  "protonvpn"
  "shottr"
  "superwhisper"
  "tailscale-app"
  "typora"

  # E2E Testing / Desktop Automation
  "hammerspoon"

  # Window Management
  "dimentium/autoraise/autoraiseapp"  # Focus follows mouse

  # Productivity Tools
  "forklift"
  "google-drive"
  "raycast"
  "reader"

  # Browsers
  # "chromium"  # Deprecated, doesn't install properly on macOS - using google-chrome for tunnel browser instead
  "google-chrome"

  # Large apps moved from nix systemPackages to reduce rsync time
  "libreoffice"
]
