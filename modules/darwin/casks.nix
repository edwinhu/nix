# Homebrew casks, split into the same LAYERS as the nix package lists
# (modules/shared/profiles.nix). A Mac that is mostly a terminal for ssh'ing
# elsewhere has no use for four GUI editors.
#
# Dropping a cask here does NOT uninstall it: `onActivation.cleanup` is off in
# modules/darwin/home-manager.nix, deliberately (it breaks accessibility
# permissions for Karabiner/Hammerspoon). So this governs what gets INSTALLED
# and managed, and an app already on disk stays until removed by hand.
{ lib, profile ? "full", ... }:

let
  layers = {
    # Always present: security, window/input management, the browser, the VPN,
    # the file manager, screenshots, Drive.
    core = [
      "1password"
      "1password-cli"  # `op`; must be the vendor binary for desktop-app integration
      "karabiner-elements"
      "homerow"
      "hammerspoon"    # E2E testing / desktop automation
      "raycast"
      "shottr"
      "tailscale-app"
      "protonvpn"
      "forklift"
      "google-drive"
      "google-chrome"
      # "chromium"  # Deprecated, doesn't install properly on macOS - using google-chrome for tunnel browser instead
    ];

    # Editors, IDEs and container tooling.
    dev = [
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
    ];

    # Chat, meetings, transcription.
    media = [
      "beeper"
      "granola"
      "macwhisper"
      "superwhisper"
      "blip"
      "zoom"
      # "morgen"  # Waiting for cask to update to 4.0.0 (currently 3.6.19)
      # "claude"  # Managed by nix run .#claude-desktop-update (Homebrew cask lags behind)
    ];

    # Notes and reading.
    pkm = [
      "obsidian"
      "reader"
      "typora"
      # libreoffice removed 2026-06-10: Word Quartz handles docx rendering; shared
      # packages keep only the lightweight x2t converter.
    ];

    # omniwm: self-managed from GitHub releases (modules/shared/omniwm.nix);
    #   the barutsrb tap lagged upstream by weeks. Copied to /Applications
    #   via modules/darwin/defaults.nix postActivation.
    # "paletro", "dimentium/autoraise/autoraiseapp": replaced by omniwm.
  };

  inherit (import ../shared/profiles.nix) layersFor layerNames;
in
assert lib.assertMsg
  (lib.all (n: lib.elem n layerNames) (builtins.attrNames layers))
  "casks.nix: declares a layer that profiles.nix does not name";
lib.concatMap (name: layers.${name} or []) (layersFor profile)
