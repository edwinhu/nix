{ pkgs }:

with pkgs; [
  # General packages for development and system management
  bash-completion
  cmake
  coreutils
  gh
  killall
  lazygit
  neovim
  nodejs
  bun
  openssh
  postgresql
  sqlite
  stow
  tldr
  wget
  yazi
  poppler-utils   # PDF previews for yazi
  zeromq
  zip

  # Encryption and security tools
  age
  gnupg
  libfido2
  sops

  # Cloud-related tools and SDKs
  google-cloud-sdk
  rclone

  # Media-related packages
  chafa
  libsixel

  # data science tools
  pixi
  uv

  # AI tools
  claude-code
  opencode

  # Text and terminal utilities
  ast-grep
  atuin
  bat
  bat-extras.batdiff
  bat-extras.batgrep
  bat-extras.batman
  bat-extras.batwatch
  bat-extras.prettybat
  btop
  numr
  direnv
  dust
  eza
  fd
  fswatch
  fzf
  hunspell
  jq
  pandoc
  ripgrep
  ripgrep-all
  starship
  tabiew
  tailspin
  tectonic
  tree
  tv
  typst
  tinymist
  unrar
  unzip
  websocat  # WebSocket client for Chrome DevTools Protocol
  wezterm
  xan
  zellij
  zoxide
]
