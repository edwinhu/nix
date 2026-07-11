# Packages for Omarchy (Arch Linux) systems
# Only includes packages NOT provided by Omarchy/pacman
{ pkgs }:

with pkgs; [
  # AI tools: installed via ~/nix/scripts/setup-ai-tools.sh
  # (claude, codex, opencode manage their own auto-updates)

  # Development tools
  bun
  cmake
  postgresql
  stow

  # Data science
  pixi
  uv

  # Communication
  beeper
  # Superhuman/Morgen CLIs (Chrome-DevTools-Protocol clients; attach to the
  # browser-wide CDP endpoint on :9222 — see hosts/linux/omarchy chromium-flags).
  superhuman-cli
  morgen-cli

  # Media: native Stremio shell (nixpkgs replacement for the removed `stremio`).
  # Uses mpv for playback so it plays .mkv/HEVC directly — no browser HLS remux,
  # which is what made web.strem.io buffer. Bundles its own streaming server.
  stremio-linux-shell

  # GPU-accelerated terminal workspace manager (gh:am-will/limux, built from
  # source — no upstream aarch64 build or flake; see modules/shared/limux.nix)
  limux

  # Cloud and sync
  google-cloud-sdk
  rclone
  croc  # fast P2P file transfer (direct over LAN when peers are local)

  # Security and secrets
  # 1password GUI: install via AUR (`yay -S 1password`) — nixpkgs _1password-gui
  # is built for NixOS (needs programs._1password-gui module for polkit/group setup).
  # 1password CLI (`op`) is installed via _1password-cli in modules/shared/packages.nix.
  age
  libfido2
  sops
  # Tailscale TUI (gh:neuralink/tsui, prebuilt release; see modules/shared/tsui.nix)
  tsui

  # Input simulation (for GUI automation/testing)
  dotool
  xdotool
  ydotool

  # Keyboard-driven GUI navigation, vimium-style (gh:AlfredoSequeida/hints,
  # built from source — see modules/shared/hints.nix). Run the `hintsd` daemon
  # to arm the global hotkey (needs the user in the `input` group).
  hints

  # Local Wayland dictation, superwhisper-style (gh:edwinhu/superwhisper-linux;
  # see modules/shared/swlinux.nix). Daemon + keybinds set up on the alarm host;
  # models fetched to ~/.local/share/swlinux/models by activation.
  swlinux

  # Terminal utilities
  atuin
  fswatch
  numr
  tabiew
  tailspin
  tree
  tv
  wget
  xan
  zellij

  # File managers
  doublecmd

  # Typesetting
  tectonic
  typst
  tinymist

  # Media and fonts
  chafa
  ueberzugpp
  lmodern
  lmmath
  maple-mono.NF
]
