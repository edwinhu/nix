{ pkgs }:

with pkgs; [
  # General packages for development and system management
  bash-completion
  cmake
  coreutils
  fh
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
  _1password-cli       # `op` — 1Password CLI (GUI installed via cask on macOS, AUR on Omarchy)
  age
  age-plugin-yubikey   # YubiKey-backed age identities for agenix
  gnupg
  libfido2
  openconnect
  pam_u2f              # optional: FIDO2-backed PAM (sudo over SSH); local sudo uses Touch ID
  sops
  yubikey-manager      # `ykman` for YubiKey configuration

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
  # claude, codex, opencode: installed via ~/nix/scripts/setup-ai-tools.sh
  # (each tool manages its own auto-updates; nix just bundles the bootstrap script)
  # omniwm: copied to /Applications via modules/darwin/defaults.nix postActivation
  gws

  # Text and terminal utilities
  ast-grep
  atuin
  bat
  btop
  numr
  direnv
  dust
  eza
  fd
  fswatch
  fzf
  hunspell
  elio
  (import ./leaf { inherit pkgs; })  # terminal Markdown previewer (LaTeX/Mermaid/watch); not in nixpkgs
  revdiff
  onlyoffice-x2t  # lightweight OOXML converter; keep source-built docbuilder out of the base system
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
