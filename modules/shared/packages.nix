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
  # `op` is NOT a nix package: desktop-app integration only accepts a CLI binary
  # the app itself vouches for (setgid `onepassword-cli` on Linux, signed on
  # macOS). Ships with the vendor install instead — pacman `1password-cli` on
  # Omarchy, the `1password-cli` cask on macOS.
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
  rv   # R package manager (modules/shared/rv.nix); new_project.sh runs `rv init`

  # semantic search
  semtools  # search "query" files... — no indexing needed

  # AI tools
  # claude, codex, opencode, agy, qmd, readwise: installed via
  # ~/nix/scripts/setup-ai-tools.sh, which writes mise stubs into ~/.local/bin
  # (no nix-tracked version pins; each tool self-updates on run).
  mise

  # omniwm: copied to /Applications via modules/darwin/defaults.nix postActivation
  (import ./nlm.nix { inherit pkgs; })
  (import ./scholar.nix { inherit pkgs; })
  (import ./consensus.nix { inherit pkgs; })
  gws

  # Text and terminal utilities
  ast-grep
  # atuin is NOT here: it comes from mise via scripts/setup-ai-tools.sh.
  # nixpkgs-unstable sits at 18.18.1, and self-hosted Atuin AI (the local
  # atuin-ai-server fronting cli-proxy-api) needs >= 18.19.0.
  # atuin's bash integration registers precmd/preexec hooks that only run if
  # bash-preexec is sourced first; without it atuin records nothing in bash.
  # Sourced from ~/.nix-profile/share/bash/bash-preexec.sh in dotfiles/.shell_common.
  bash-preexec
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
  onlyoffice-x2t  # lightweight OOXML converter; keep source-built docbuilder out of the base system
  jq
  pandoc
  haskellPackages.pandoc-crossref
  ripgrep
  ripgrep-all
  herdr  # agent multiplexer TUI (replaces limux/cmux); flake input, see flake.nix
  starship
  tabiew
  tailspin
  tectonic
  tree
  tuicr  # code-review TUI (in nixpkgs); replaces revdiff, driven by the tuicr Claude skill
  tv
  typst
  tinymist
  unrar
  unzip
  croc  # fast P2P file transfer (direct over LAN when peers are local)
  websocat  # WebSocket client for Chrome DevTools Protocol
  # chrome-for-testing  # Removed: 338 MB app bundle slowed rsync; use homebrew google-chrome instead
  wezterm
  xan
  zellij
  zoxide
]
