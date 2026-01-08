# Packages for Omarchy (Arch Linux) systems
# Only includes packages NOT provided by Omarchy/pacman
{ pkgs }:

with pkgs; [
  # AI tools (custom nix builds)
  claude-code
  opencode

  # Development tools
  bun
  cmake
  postgresql
  stow

  # Data science
  pixi
  uv

  # Cloud and sync
  google-cloud-sdk
  localsend
  rclone

  # Security and secrets
  age
  libfido2
  sops

  # Terminal utilities
  atuin
  bat-extras.batdiff
  bat-extras.batgrep
  bat-extras.batman
  bat-extras.batwatch
  bat-extras.prettybat
  fswatch
  numr
  tabiew
  tailspin
  tree
  tv
  wget
  xan
  zellij

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
