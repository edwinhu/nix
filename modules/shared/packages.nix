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
  # bitwarden-cli  # TODO: re-enable after nodejs-slim-22 OOM fix
  gnupg
  libfido2
  sops

  # Cloud-related tools and SDKs
  google-cloud-sdk
  rclone

  # Media-related packages
  chafa
  libsixel

  # Document processing
  lmodern

  # data science tools
  pixi
  uv

  # semantic search
  semtools  # search "query" files... — no indexing needed

  # AI tools
  # claude, codex, opencode, the-companion: installed via ~/nix/scripts/setup-ai-tools.sh
  # (each tool manages its own auto-updates; nix just bundles the bootstrap script)
  # happy-app: copied to /Applications via modules/darwin/defaults.nix postActivation
  gws

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
  haskellPackages.pandoc-crossref
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
  # chrome-for-testing  # Removed: 338 MB app bundle slowed rsync; use homebrew google-chrome instead
  wezterm
  xan
  zellij
  zoxide
]
