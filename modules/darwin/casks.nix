_:

[
  # Development Tools
  "orbstack"
  "github"
  # cmux: auto_updates cask — brew/nix do NOT manage its version; the app self-updates via Sparkle.
  # PINNED to 0.64.10 manually (2026-06-01): 0.64.11's new "detachable SSH PTY daemon" breaks remote
  # reattach across daemon-version boundaries -> "ssh-pty-attach: remote PTY attach failed".
  # FIX: upstream PR manaflow-ai/cmux#5088 (version-scoped snapshot restore w/ fresh-SSH fallback).
  # UN-PIN once #5088 ships in a release AFTER 0.64.11, then re-enable Sparkle:
  #   defaults write com.cmuxterm.app SUEnableAutomaticChecks -bool true
  # Pin enforced by disabling Sparkle:
  #   defaults write com.cmuxterm.app SUEnableAutomaticChecks -bool false
  #   defaults write com.cmuxterm.app SUAutomaticallyUpdate   -bool false
  # Remote sessions are better persisted with zellij on the host anyway
  # (`ssh rjds && zellij attach <session>`).
  "cmux"
  "codex-app"
  "antigravity"  # Antigravity IDE 2.0 (Google, ex-Firebase Studio); CLI installed via setup-ai-tools
  "neovide-app"
  "visual-studio-code"
  # "wezterm"  # Removed: using nix package for version consistency across systems
  "zed"

  # Communication Tools
  "beeper"
  # macOS-only; the Linux stand-in is openwhispr (modules/linux/omarchy-packages.nix)
  "granola"
  "macwhisper"
  "superhuman"
  "zoom"

  # Utility Tools
  "1password"
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
