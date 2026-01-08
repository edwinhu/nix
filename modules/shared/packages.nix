{ pkgs }:

with pkgs; [
  # General packages for development and system management
  bash-completion
  cmake
  coreutils
  gh
  killall
  lazygit
  localsend
  neofetch
  neovim
  nodejs
  bun
  openssh
  postgresql
  zathura
  sox
  sqlite
  stow
  tldr
  wget
  yazi
  ueberzugpp      # Image rendering backend for yazi
  ffmpegthumbnailer  # Video thumbnails for yazi
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
  cm_unicode
  dejavu_fonts
  font-awesome
  libsixel
  noto-fonts
  noto-fonts-color-emoji

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
  wezterm
  xan
  zellij
  zoxide

  # Fonts - only install needed nerd fonts to save space
  # Changed from: builtins.attrValues pkgs.nerd-fonts (installs all ~7GB!)
  # To: only maple-mono (saves ~6GB)
  maple-mono.NF
]
