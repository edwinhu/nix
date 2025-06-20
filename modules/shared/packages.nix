{ pkgs }:

with pkgs; [
  # General packages for development and system management
  aspell
  aspellDicts.en
  bash-completion
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
  sox
  sqlite
  stow
  wget
  yazi
  zip

  # Encryption and security tools
  gnupg
  libfido2

  # Cloud-related tools and SDKs
  rclone

  # Media-related packages
  dejavu_fonts
  font-awesome
  hack-font
  jetbrains-mono
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
  pandoc
  ripgrep
  tectonic
  tmux
  tree
  starship
  typst
  unrar
  unzip
  xan
  zoxide
] 
# nerd fonts unbundled
++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts)
