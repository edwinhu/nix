_:

[
  # Development Tools
  "orbstack"
  "github"
  # cmux removed (2026-07-27) along with its Linux port limux: replaced by herdr,
  # a single cross-platform TUI binary (see modules/shared/packages.nix). No more
  # Sparkle self-update pin to babysit, and no GUI app to keep in the dock.
  "codex-app"
  "antigravity"  # Antigravity IDE 2.0 (Google, ex-Firebase Studio); CLI installed via setup-ai-tools
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
  "1password"
  "1password-cli"  # `op`; must be the vendor binary for desktop-app integration
  "blip"
  "karabiner-elements"
  # "claude"  # Managed by nix run .#claude-desktop-update (Homebrew cask lags behind)
  "homerow"
  # "morgen"  # Waiting for cask to update to 4.0.0 (currently 3.6.19)
  "obsidian"
  # "paletro"  # Replaced by omniwm
  "protonvpn"
  "shottr"
  "superwhisper"
  "tailscale-app"
  "typora"

  # E2E Testing / Desktop Automation
  "hammerspoon"

  # Window Management
  # "dimentium/autoraise/autoraiseapp"  # Replaced by omniwm
  # omniwm: self-managed from GitHub releases (modules/shared/omniwm.nix);
  #   the barutsrb tap lagged upstream by weeks. Copied to /Applications
  #   via modules/darwin/defaults.nix postActivation.

  # Productivity Tools
  "forklift"
  "google-drive"
  "raycast"
  "reader"

  # Browsers
  # "chromium"  # Deprecated, doesn't install properly on macOS - using google-chrome for tunnel browser instead
  "google-chrome"

  # libreoffice removed 2026-06-10: Word Quartz handles docx rendering; shared
  # packages keep only the lightweight x2t converter.
]
