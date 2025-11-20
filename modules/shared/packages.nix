{ pkgs }:

with pkgs; [
  # General packages for development and system management
  aspell
  aspellDicts.en
  bash-completion
  cmake
  coreutils
  gh
  gh-copilot
  killall
  lazygit
  libtool
  localsend
  neofetch
  neovim
  nodejs
  openssh
  postgresql
  sioyek
  sox
  sqlite
  stow
  tldr
  wget
  yazi
  ueberzugpp      # Image rendering backend for yazi
  ffmpegthumbnailer  # Video thumbnails for yazi
  poppler_utils   # PDF previews for yazi
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

  # Virtualization
  lima

  # Media-related packages
  chafa
  cm_unicode
  dejavu_fonts
  font-awesome
  hack-font
  jetbrains-mono
  libsixel
  meslo-lgs-nf
  noto-fonts
  noto-fonts-emoji

  # data science tools
  pixi
  uv

  # AI tools
  claude-code

  # Rust toolchain for Zed extension development
  rustup
  emscripten

  # Text and terminal utilities
  atuin
  bat
  bat-extras.batdiff
  bat-extras.batgrep
  bat-extras.batman
  bat-extras.batwatch
  bat-extras.prettybat
  btop
  direnv
  du-dust
  eza
  fd
  fswatch
  fzf
  hunspell
  jq
  ollama
  pandoc
  ripgrep
  ripgrep-all
  starship
  tabiew
  tailspin
  tectonic
  tmux
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
  # To: only jetbrains-mono (saves ~6GB)
  nerd-fonts.jetbrains-mono
]
