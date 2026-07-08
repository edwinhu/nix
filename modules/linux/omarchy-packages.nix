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

  # AI agent terminal multiplexer (gh:no1msd/seance, packaged via flake input)
  seance

  # Cloud and sync
  google-cloud-sdk
  rclone

  # Security and secrets
  # 1password GUI: install via AUR (`yay -S 1password`) — nixpkgs _1password-gui
  # is built for NixOS (needs programs._1password-gui module for polkit/group setup).
  # 1password CLI (`op`) is installed via _1password-cli in modules/shared/packages.nix.
  age
  libfido2
  sops

  # Input simulation (for GUI automation/testing)
  dotool
  xdotool
  ydotool

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
