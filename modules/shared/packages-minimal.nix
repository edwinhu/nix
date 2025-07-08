{ pkgs }:

with pkgs; [
  # Data science tools
  pixi
  pixi-pack
  
  # Terminal utilities
  atuin
  bat
  direnv
  du-dust
  eza
  fd
  fzf
  gh
  jq
  ripgrep
  rclone
  starship
  stow
  wezterm
  xan
  yazi
  zoxide
]