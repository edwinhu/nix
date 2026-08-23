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
  # bun-pinned, not stock bun: nixpkgs' 1.3.13 makes IMAP SEARCH ~47x slower and
  # lifts test module poison, and mail-bridge is COMPILED with the pinned 1.3.14
  # (flake.nix). An interactive bun on a different version than the shipped
  # binary is the inconsistency this removes. See bun-pinned.nix.
  (pkgs.callPackage ./bun-pinned.nix {})
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

  # Language servers for Claude Code's LSP plugins (pyright-lsp, gopls-lsp,
  # typescript-lsp, rust-analyzer-lsp). These MUST be global: Claude Code
  # resolves an LSP `command` from PATH only -- never a project venv, pixi env
  # or node_modules/.bin -- so a project-local server is unreachable. Project
  # fidelity comes from config instead (pyrightconfig.json names the
  # interpreter; typescript-language-server loads the project's own tsserver
  # from node_modules when there is one, and falls back to the `typescript`
  # here otherwise). One per language actually used across ~/projects:
  # python, go, typescript, rust.
  pyright
  gopls
  typescript-language-server
  typescript
  rust-analyzer

  # Linters and formatters for those same four languages. These are a FALLBACK
  # for ad-hoc use, never the authority: a project that pins its own ruff or
  # eslint (pyproject.toml, pixi, package.json) must keep winning locally, or
  # the global version quietly disagrees with CI. nodePackages.eslint and
  # nodePackages.prettier no longer exist -- the top-level attrs are the ones.
  ruff
  mypy
  golangci-lint
  eslint
  prettier
  clippy
  rustfmt

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
  (import ./linecast.nix { inherit pkgs; })
  (import ./kefctl.nix { inherit pkgs; })
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
  # herdr is NOT here: mise via scripts/setup-ai-tools.sh, which also
  # regenerates its agent skill from the same binary.
  starship
  tabiew
  tailspin
  tectonic
  tree
  tuicr  # code-review TUI (in nixpkgs); replaces revdiff, driven by the tuicr Claude skill
  tv
  typst
  tinymist
  # tinymist-lsp: wrapper that injects the project root into the LSP
  # initialize request; tinymist has no --root flag and Claude Code cannot send
  # initializationOptions. See modules/shared/tinymist-lsp.nix.
  tinymist-lsp
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
