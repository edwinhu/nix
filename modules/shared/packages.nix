# Cross-platform packages, split into LAYERS and composed into PROFILES.
#
#   import ./packages.nix { inherit pkgs; }                  -> the full set
#   import ./packages.nix { inherit pkgs; profile = "client"; }
#
# A profile names which layers a host gets. Not every machine is the main
# machine: `client` is a box that only drives LLM CLIs and `herdr --remote`
# into omarchy, `server` is headless (rjds) and has no use for mail, PKM,
# typesetting or media.
#
# Adding a tool means putting it in ONE layer. Adding a host means picking a
# profile in flake.nix, never editing a package list.
{ pkgs, profile ? "full" }:

let
  inherit (pkgs) lib;

  layers = with pkgs; {

    # Shell, files, search, VCS, secrets. Everything a machine needs to be
    # usable over SSH and to run this flake. Every profile gets this.
    core = [
      bash-completion
      coreutils
      fh
      gh
      killall
      lazygit
      neovim
      openssh
      stow
      # zsh: yazi's fazif plugin shells out to it, and on a host where the
      # login shell is the nix one, dropping it from a profile locks you out.
      # Core, not a leaf layer, for that second reason.
      zsh
      tldr
      wget
      sqlite
      zip
      unzip
      unrar

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
      jq
      ripgrep
      ripgrep-all
      starship
      tailspin
      tree
      tv
      zoxide
      zellij
      # herdr is NOT here: mise via scripts/setup-ai-tools.sh, which also
      # regenerates its agent skill from the same binary. A client profile
      # exists mostly to run `herdr --remote`, so this layer is its floor.
      croc  # fast P2P file transfer (direct over LAN when peers are local)
      websocat  # WebSocket client for Chrome DevTools Protocol

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
    ];

    # AI CLIs and the machinery that installs them.
    ai = [
      # claude, codex, opencode, agy, qmd, readwise: installed via
      # ~/nix/scripts/setup-ai-tools.sh, which writes mise stubs into ~/.local/bin
      # (no nix-tracked version pins; each tool self-updates on run).
      mise
      # semantic search
      semtools  # search "query" files... — no indexing needed
      ast-grep
    ];

    # Compilers, language servers, linters. A machine that only drives remote
    # agents does not need these; a machine that edits code does.
    dev = [
      cmake
      nodejs
      # bun-pinned, not stock bun: nixpkgs' 1.3.13 makes IMAP SEARCH ~47x slower and
      # lifts test module poison, and mail-bridge is COMPILED with the pinned 1.3.14
      # (flake.nix). An interactive bun on a different version than the shipped
      # binary is the inconsistency this removes. See bun-pinned.nix.
      (pkgs.callPackage ./bun-pinned.nix {})
      zeromq

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
      go              # gopls is inert without the toolchain: it shells out to `go list`
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

      tuicr  # code-review TUI (in nixpkgs); replaces revdiff, driven by the tuicr Claude skill
    ];

    # Cloud SDKs and remote storage.
    cloud = [
      google-cloud-sdk
      rclone
      gws
      postgresql
    ];

    # Data science and tabular work.
    data = [
      pixi
      uv
      rv   # R package manager (modules/shared/rv.nix); new_project.sh runs `rv init`
      xan
      tabiew
    ];

    # Typesetting, document conversion, file preview.
    docs = [
      pandoc
      haskellPackages.pandoc-crossref
      typst
      tinymist
      # tinymist-lsp: wrapper that injects the project root into the LSP
      # initialize request; tinymist has no --root flag and Claude Code cannot send
      # initializationOptions. See modules/shared/tinymist-lsp.nix.
      tinymist-lsp
      tectonic
      lmodern
      hunspell
      elio
      (import ./leaf { inherit pkgs; })  # terminal Markdown previewer (LaTeX/Mermaid/watch); not in nixpkgs
      onlyoffice-x2t  # lightweight OOXML converter; keep source-built docbuilder out of the base system
      yazi
      poppler-utils   # PDF previews for yazi
    ];

    # Personal knowledge management and research CLIs.
    pkm = [
      (import ./nlm.nix { inherit pkgs; })
      (import ./scholar.nix { inherit pkgs; })
      (import ./consensus.nix { inherit pkgs; })
      (import ./linecast.nix { inherit pkgs; })
    ];

    # Terminals, media, and hardware the headless/thin hosts have no use for.
    media = [
      chafa
      libsixel
      (import ./kefctl.nix { inherit pkgs; })
      # chrome-for-testing  # Removed: 338 MB app bundle slowed rsync; use homebrew google-chrome instead
      wezterm
    ];
  };

  # Which layers each profile gets. `full` must be every layer — the assertion
  # below is what keeps that true when a layer is added.
  profiles = {
    full   = builtins.attrNames layers;
    client = [ "core" "ai" ];
    server = [ "core" "ai" "dev" "cloud" "data" ];
  };

  selected = profiles.${profile} or (throw
    "shared/packages.nix: unknown profile '${profile}'; known: ${
      lib.concatStringsSep ", " (builtins.attrNames profiles)}");
in
assert lib.assertMsg (profiles.full == builtins.attrNames layers)
  "shared/packages.nix: the `full` profile must list every layer";
lib.concatMap (name: layers.${name}) selected
