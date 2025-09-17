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
  zeromq
  zip

  # Encryption and security tools
  age
  gnupg
  libfido2
  sops

  # Cloud-related tools and SDKs
  rclone

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
  hunspell
  fzf
  jq
  ollama
  pandoc
  ripgrep
  tailspin
  tectonic
  tmux
  tree
  starship
  typst
  unrar
  unzip
  xan
  zellij
  zellij-switch
  zoxide
] 
# nerd fonts unbundled
++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts)
