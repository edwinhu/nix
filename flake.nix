{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    # Newer nixpkgs pin for onlyoffice-docbuilder only: the main lock predates
    # pkgs/by-name/on/onlyoffice-documentserver/x2t.nix (hermetic source build
    # that our docbuilder derivation extends). Safe to fold into nixpkgs on
    # the next full lock update.
    nixpkgs-onlyoffice.url = "github:nixos/nixpkgs/8c3cede7ddc26bd659d2d383b5610efbd2c7a16e";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew = {
      url = "github:zhaofengli-wip/nix-homebrew";
    };
    homebrew-bundle = {
      url = "github:homebrew/homebrew-bundle";
      flake = false;
    };
    zellij-switch-wasm = {
      url = "https://github.com/mostafaqanbaryan/zellij-switch/releases/latest/download/zellij-switch.wasm";
      flake = false;
    };
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
    presmihaylov-taps = {
      url = "github:presmihaylov/homebrew-taps";
      flake = false;
    };
    dimentium-autoraise = {
      url = "github:Dimentium/homebrew-autoraise";
      flake = false;
    };
    stylix = {
      url = "github:danth/stylix";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixGL = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-secrets = {
      url = "git+ssh://git@github.com/edwinhu/nix-secrets.git";
      flake = false;
    };
    # swlinux: local Wayland dictation tool (private repo, SSH-fetched like secrets)
    swlinux-src = {
      url = "git+ssh://git@github.com/edwinhu/superwhisper-linux.git";
      flake = false;
    };
    # joycon-pad: Joy-Con macro pad daemon (private repo, SSH-fetched like swlinux)
    joycon-pad-src = {
      url = "git+ssh://git@github.com/edwinhu/joycon-pad.git";
      flake = false;
    };
  };

  outputs = { self, darwin, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, presmihaylov-taps, dimentium-autoraise, home-manager, nixpkgs, nixpkgs-onlyoffice, stylix, agenix, nixGL, nix-secrets, zellij-switch-wasm, swlinux-src, joycon-pad-src } @inputs:
    let
      # Define user-host mappings
      userHosts = {
        vwh7mb = {
          system = "aarch64-darwin";
          host = "macbook-pro";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
        edwinhu = {
          system = "aarch64-darwin";
          host = "mba";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
        eh2889 = {
          system = "x86_64-linux";
          host = "rjds";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
        # Omarchy (Arch Linux) desktop - uses minimal nix config, dotfiles managed separately
        # Key is "edwinhu-alarm" to avoid conflict with MBA's edwinhu, but actual username is edwinhu
        "edwinhu-alarm" = {
          system = "aarch64-linux";
          host = "alarm";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
          username = "edwinhu";  # Actual username on the system
        };
        # Omarchy (Arch Linux) on Framework Desktop (AMD Ryzen AI Max, x86_64)
        # Config key == username "eh", so build-switch resolves it with no special case.
        eh = {
          system = "x86_64-linux";
          host = "omarchy";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
      };
      
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs (linuxSystems ++ darwinSystems) f;
      devShell = system: let pkgs = nixpkgs.legacyPackages.${system}; in {
        default = with pkgs; mkShell {
          nativeBuildInputs = with pkgs; [ bashInteractive git sops ];
          shellHook = with pkgs; ''
            export EDITOR=vim
          '';
        };
      };
      mkApp = scriptName: system: {
        type = "app";
        program = "${(nixpkgs.legacyPackages.${system}.writeScriptBin scriptName ''
          #!/usr/bin/env bash
          PATH=${nixpkgs.legacyPackages.${system}.git}/bin:$PATH
          echo "Running ${scriptName} for ${system}"
          exec bash ${self}/apps/${system}/${scriptName} "$@"
        '')}/bin/${scriptName}";
        meta.description = "Run ${scriptName} for ${system}";
      };
      mkSetupAiToolsApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Bootstrap-install claude, codex, opencode, agy (idempotent)";
        program = "${(pkgs.writeScriptBin "setup-ai-tools" ''
          #!/usr/bin/env bash
          exec ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh "$@"
        '')}/bin/setup-ai-tools";
      };
      mkUpdateAiToolsApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Force-reinstall claude, codex, opencode, agy to latest";
        program = "${(pkgs.writeScriptBin "update-ai-tools" ''
          #!/usr/bin/env bash
          exec ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh --force "$@"
        '')}/bin/update-ai-tools";
      };
      mkClaudeDesktopUpdateApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Update Claude Desktop to latest version";
        program = "${(pkgs.writeScriptBin "claude-desktop-update" ''
          #!/usr/bin/env bash
          set -euo pipefail

          GREEN='\033[1;32m'
          YELLOW='\033[1;33m'
          RED='\033[1;31m'
          NC='\033[0m'

          RELEASES_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"

          echo -e "''${YELLOW}Checking for updates...''${NC}"
          RELEASES_JSON=$(${pkgs.curl}/bin/curl -sfS "''$RELEASES_URL")
          LATEST=$(echo "''$RELEASES_JSON" | ${pkgs.jq}/bin/jq -r '.currentRelease')
          ZIP_URL=$(echo "''$RELEASES_JSON" | ${pkgs.jq}/bin/jq -r '.releases[0].updateTo.url')

          CURRENT=$(/usr/bin/defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "not installed")
          echo "Current: ''$CURRENT  Latest: ''$LATEST"

          if [ "''$CURRENT" = "''$LATEST" ]; then
            echo -e "''${GREEN}Already up to date.''${NC}"
            exit 0
          fi

          TMPDIR=$(mktemp -d)
          trap 'rm -rf "''$TMPDIR"' EXIT

          echo -e "''${YELLOW}Downloading Claude Desktop ''$LATEST...''${NC}"
          ${pkgs.curl}/bin/curl -fSL -o "''$TMPDIR/Claude.zip" "''$ZIP_URL"

          echo -e "''${YELLOW}Installing...''${NC}"
          ${pkgs.unzip}/bin/unzip -qo "''$TMPDIR/Claude.zip" -d "''$TMPDIR"

          # Close Claude Desktop if running
          if pgrep -x "Claude" > /dev/null 2>&1; then
            echo -e "''${YELLOW}Closing Claude Desktop...''${NC}"
            osascript -e 'quit app "Claude"' 2>/dev/null || true
            sleep 2
          fi

          # Homebrew-installed casks have root ownership; need sudo to replace
          sudo rm -rf /Applications/Claude.app
          sudo mv "''$TMPDIR/Claude.app" /Applications/
          sudo chown -R "$(whoami 2>/dev/null || echo "$USER")" /Applications/Claude.app

          echo -e "''${GREEN}Updated Claude Desktop to ''$LATEST''${NC}"
          echo "Opening Claude Desktop..."
          open -a Claude
        '')}/bin/claude-desktop-update";
      };
      mkLinuxApps = system: {
        "apply" = mkApp "apply" system;
        "build-switch" = mkApp "build-switch" system;
        "setup-ai-tools" = mkSetupAiToolsApp system;
        "update-ai-tools" = mkUpdateAiToolsApp system;
        "copy-keys" = mkApp "copy-keys" system;
        "create-keys" = mkApp "create-keys" system;
        "check-keys" = mkApp "check-keys" system;
        "install" = mkApp "install" system;
        "install-with-secrets" = mkApp "install-with-secrets" system;
      };
      mkDarwinApps = system: {
        "apply" = mkApp "apply" system;
        "build" = mkApp "build" system;
        "build-switch" = mkApp "build-switch" system;
        "setup-ai-tools" = mkSetupAiToolsApp system;
        "update-ai-tools" = mkUpdateAiToolsApp system;
        "claude-desktop-update" = mkClaudeDesktopUpdateApp system;
        "copy-keys" = mkApp "copy-keys" system;
        "create-keys" = mkApp "create-keys" system;
        "check-keys" = mkApp "check-keys" system;
        "rollback" = mkApp "rollback" system;
      };
    in
    {
      devShells = forAllSystems devShell;
      apps = nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

      # Expose custom packages for quick updates without full rebuild
      packages = forAllSystems (system: {
        gws = (import nixpkgs { inherit system; }).callPackage ./modules/shared/gws.nix {};
        # chrome-for-testing: removed from build to reduce rsync time (338 MB app bundle)
        # chrome-for-testing = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/chrome-for-testing.nix {};
        superhuman-cli = (import nixpkgs { inherit system; }).callPackage ./modules/shared/superhuman-cli.nix {};
        morgen-cli = (import nixpkgs { inherit system; }).callPackage ./modules/shared/morgen-cli.nix {};
        omniwm = (import nixpkgs { inherit system; }).callPackage ./modules/shared/omniwm.nix {};
        # elio via newer nixpkgs: the main lock's cargo vendor fetcher sends
        # no User-Agent and crates.io now 403s it (affects all platforms).
        elio = (import inputs.nixpkgs-onlyoffice { inherit system; }).callPackage ./modules/shared/elio.nix {};
        onlyoffice-x2t = (import nixpkgs { inherit system; }).callPackage ./modules/shared/onlyoffice-x2t.nix {};
        onlyoffice-docbuilder = (import inputs.nixpkgs-onlyoffice { inherit system; }).callPackage ./modules/shared/onlyoffice/docbuilder.nix {};
      });

      # Darwin configurations for macOS hosts
      darwinConfigurations = let
        darwinUsers = nixpkgs.lib.filterAttrs (user: info: nixpkgs.lib.hasSuffix "darwin" info.system) userHosts;
      in nixpkgs.lib.mapAttrs (user: info:
        darwin.lib.darwinSystem {
          system = info.system;
          specialArgs = inputs // { inherit user nix-secrets; userInfo = info; };
          modules = [
            ({ pkgs, ... }: {
              nixpkgs.overlays = [
                (final: prev: {
                  zellij-switch = prev.runCommand "zellij-switch" {} ''
                    mkdir -p $out/share/zellij/plugins
                    cp ${zellij-switch-wasm} $out/share/zellij/plugins/zellij-switch.wasm
                  '';
                  gws = prev.callPackage ./modules/shared/gws.nix {};
                  # chrome-for-testing: removed from overlay to reduce rsync time
                  # chrome-for-testing = prev.callPackage ./modules/shared/chrome-for-testing.nix {};
                  superhuman-cli = prev.callPackage ./modules/shared/superhuman-cli.nix {};
                  morgen-cli = prev.callPackage ./modules/shared/morgen-cli.nix {};
                  paperpile-cli = prev.callPackage ./modules/shared/paperpile-cli.nix {};
                  omniwm = prev.callPackage ./modules/shared/omniwm.nix {};
                  # elio via newer nixpkgs: the main lock's cargo vendor fetcher
                  # sends no User-Agent and crates.io now 403s it.
                  elio = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/elio.nix {};
                  onlyoffice-x2t = prev.callPackage ./modules/shared/onlyoffice-x2t.nix {};
                  onlyoffice-docbuilder = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/onlyoffice/docbuilder.nix {};
                    # ast-grep 0.41.0 test_scan_invalid_rule_id fails with "Illegal byte sequence"
                  # on macOS after nixpkgs update to 2026-03-08
                  ast-grep = prev.ast-grep.overrideAttrs (old: {
                    doCheck = false;
                  });
                })
              ];
              
              environment.variables = {
                ZELLIJ_SWITCH_PLUGIN = "${pkgs.zellij-switch}/share/zellij/plugins/zellij-switch.wasm";
              };

              # Disable the nix-darwin HTML manual (darwin-manual-html). As of
              # nixpkgs 2026-07 nixos-render-docs removed the --toc-depth flag
              # (use --sidebar-depth), but nix-darwin master (a1fa429, 2026-06-18)
              # still passes --toc-depth, so the manual build fails. It's purely
              # local docs; man pages (documentation.man) are unaffected.
              documentation.doc.enable = false;
              # The uninstaller tool embeds its own default-config darwin-system,
              # which rebuilds the broken manual regardless of the setting above.
              # Drop it from the system path (re-enable once upstream fixes docs).
              system.tools.darwin-uninstaller.enable = false;
            })
            agenix.darwinModules.default
            inputs.stylix.darwinModules.stylix
            inputs.home-manager.darwinModules.home-manager
            nix-homebrew.darwinModules.nix-homebrew
            {
              nix-homebrew = {
                inherit user;
                enable = true;
                taps = {
                  "homebrew/homebrew-core" = homebrew-core;
                  "homebrew/homebrew-cask" = homebrew-cask;
                  "homebrew/homebrew-bundle" = homebrew-bundle;
                  "presmihaylov/homebrew-taps" = presmihaylov-taps;
                  "dimentium/homebrew-autoraise" = dimentium-autoraise;
                };
                mutableTaps = false;
                autoMigrate = true;
              };
            }
            { nix.enable = false; }
            ./hosts/darwin/${info.host}
          ];
        }
      ) darwinUsers;

      # Home-manager configurations for Linux hosts
      homeConfigurations = let
        linuxUsers = nixpkgs.lib.filterAttrs (user: info: nixpkgs.lib.hasSuffix "linux" info.system) userHosts;
      in nixpkgs.lib.mapAttrs (configKey: info:
        let
          # Use info.username if set, otherwise fall back to the config key
          user = info.username or configKey;
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = info.system;
            config.allowUnfree = true;
            overlays = [
              (final: prev: {
                gws = prev.callPackage ./modules/shared/gws.nix {};
                superhuman-cli = prev.callPackage ./modules/shared/superhuman-cli.nix {};
                morgen-cli = prev.callPackage ./modules/shared/morgen-cli.nix {};
                paperpile-cli = prev.callPackage ./modules/shared/paperpile-cli.nix {};
                tsui = prev.callPackage ./modules/shared/tsui.nix {};
                # elio via newer nixpkgs: the main lock's cargo vendor fetcher
                # sends no User-Agent and crates.io now 403s it.
                elio = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/elio.nix {};
                onlyoffice-x2t = prev.callPackage ./modules/shared/onlyoffice-x2t.nix {};
                onlyoffice-docbuilder = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/onlyoffice/docbuilder.nix {};
                # limux is a GPU/GL app (libghostty + GTK4). Like beeper, on a
                # non-NixOS host it can't find system Mesa/EGL and dies with
                # "failed to create EGL display" — wrap bin/limux in nixGLIntel
                # (the wrapper's GL env is inherited by the limux-host child that
                # actually creates the GL context). x86_64/aarch64 both need it.
                limux = let
                  # Pin ghostty to the UNWRAPPED package: the overlay's `ghostty`
                  # is a nixGL symlinkJoin, which flattens the multi-output derivation
                  # and so drops the `terminfo` output limux.nix copies from. limux
                  # only wants ghostty's share/ resources + terminfo — it never runs
                  # the binary, and carries its own nixGL wrapper — so the wrap is
                  # both unnecessary and lossy here.
                  limuxPkg = prev.callPackage ./modules/shared/limux.nix {
                    ghostty = prev.ghostty;
                  };
                in prev.symlinkJoin {
                  name = "limux-nixgl-${limuxPkg.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "limux" ''
                      # Unset GDK_SCALE (Omarchy sets =2 globally in monitors.conf):
                      # libghostty does its own HiDPI scaling from the compositor's
                      # 2x wl_output, so GDK_SCALE=2 double-scales -> huge terminal.
                      exec env -u GDK_SCALE ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${limuxPkg}/bin/limux "$@"
                    '')
                    limuxPkg
                  ];
                  # limux's dev.limux.linux.desktop hard-codes Exec/TryExec to the
                  # UNWRAPPED ${limuxPkg}/bin/limux, so launching from the launcher
                  # bypasses the nixGL wrap -> "failed to create EGL display".
                  # Replace the symlinked desktop file with one whose Exec/TryExec
                  # point at the wrapped $out/bin/limux.
                  postBuild = ''
                    d=$out/share/applications/dev.limux.linux.desktop
                    if [ -e "$d" ]; then
                      rm -f "$d"
                      sed "s|${limuxPkg}/bin/limux|$out/bin/limux|g" \
                        ${limuxPkg}/share/applications/dev.limux.linux.desktop > "$d"
                    fi
                  '';
                  meta = limuxPkg.meta or {};
                  passthru = { unwrapped = limuxPkg; };
                };
                # ghostty is the default terminal on Omarchy (xdg-terminals.list,
                # host module). Same GPU/GL story as limux — it's the same GTK4 +
                # libghostty renderer — so unwrapped it dies with "failed to make
                # GL context current: Failed to create EGL display" on this
                # non-NixOS host. Verified: bare binary fails, nixGLIntel-wrapped
                # renders a surface and exits 0.
                ghostty = let
                  ghosttyPkg = prev.ghostty;
                in prev.symlinkJoin {
                  name = "ghostty-nixgl-${ghosttyPkg.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "ghostty" ''
                      # Unset GDK_SCALE (Omarchy sets =2 globally in monitors.conf):
                      # ghostty already scales from the compositor's 2x wl_output,
                      # so GDK_SCALE=2 double-scales -> huge terminal. Same fix as
                      # limux, which embeds the same renderer.
                      exec env -u GDK_SCALE ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${ghosttyPkg}/bin/ghostty "$@"
                    '')
                    ghosttyPkg
                  ];
                  # com.mitchellh.ghostty.desktop hard-codes Exec/TryExec to the
                  # UNWRAPPED ${ghosttyPkg}/bin/ghostty, so every launcher path —
                  # including xdg-terminal-exec, i.e. SUPER+RETURN — would bypass
                  # the nixGL wrap and hit the EGL error. Repoint both at the
                  # wrapped $out/bin/ghostty.
                  postBuild = ''
                    d=$out/share/applications/com.mitchellh.ghostty.desktop
                    if [ -e "$d" ]; then
                      rm -f "$d"
                      sed "s|${ghosttyPkg}/bin/ghostty|$out/bin/ghostty|g" \
                        ${ghosttyPkg}/share/applications/com.mitchellh.ghostty.desktop > "$d"
                    fi
                  '';
                  meta = ghosttyPkg.meta or {};
                  passthru = (ghosttyPkg.passthru or {}) // { unwrapped = ghosttyPkg; };
                };
                # stremio-linux-shell uses mpv (GL) — same as beeper/limux, wrap
                # bin/stremio in nixGLIntel so it finds system Mesa/EGL on non-NixOS
                # ("failed to create EGL display" otherwise). Also pass
                # --no-window-decorations: the app's client-side titlebar adds
                # nothing under Hyprland's tiling.
                stremio-linux-shell = let
                  base = prev.stremio-linux-shell;
                in prev.symlinkJoin {
                  name = "stremio-linux-shell-nixgl-${base.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "stremio" ''
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/stremio --no-window-decorations "$@"
                    '')
                    base
                  ];
                  meta = base.meta or {};
                  passthru = { unwrapped = base; };
                };
                # hylo — Edwin's own Electron PDF reader (gh:edwinhu/hylo),
                # fetched as the release AppImage (see modules/shared/hylo.nix).
                # Same GL story as beeper/stremio/limux: wrap bin/hylo in
                # nixGLIntel so Chromium/Mesa resolve against system GL on
                # non-NixOS (Omarchy has no /run/opengl-driver; nixGLIntel drives
                # AMD too), and force --no-sandbox — the store chrome-sandbox is
                # not setuid. The wrapped `hylo` on PATH is what xdg-open (via
                # xdg.desktopEntries.hylo) invokes as the default PDF handler.
                hylo = let
                  hyloPkg = prev.callPackage ./modules/shared/hylo.nix {};
                in prev.symlinkJoin {
                  name = "hylo-nixgl-${hyloPkg.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "hylo" ''
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${hyloPkg}/bin/hylo --no-sandbox "$@"
                    '')
                    hyloPkg
                  ];
                  meta = hyloPkg.meta or {};
                  passthru = { unwrapped = hyloPkg; };
                };
                # obsidian — nix-managed, replacing the Arch `obsidian` package
                # (pacman) that runs Obsidian's app.asar on the DISTRO
                # `electron39`. That build breaks the in-app PDF preview: PDF.js
                # fetches the vault file over Obsidian's internal `app://` scheme
                # (served from a per-vault host, `app://<hash>/…`, while the app
                # runs on `app://obsidian.md`), and Arch's electron39 blocks that
                # cross-origin fetch with a CORS error ("Unexpected server
                # response (0)"), so every PDF renders blank (0 page canvases).
                # It is NOT a GPU/nixGL problem — measured: Obsidian's OFFICIAL
                # tarball on electron 39.8.3 (same Chromium 142 as Arch's 39.8.10)
                # renders fine, and so does this nixpkgs build on electron 41
                # (Chromium 146). Only Arch's patched electron39 mishandles the
                # scheme. Fix = run on nixpkgs' electron. Wrapped in nixGLIntel
                # for the usual non-NixOS GL story (hylo/beeper); nixGL is a no-op
                # where system GL already resolves, and the app's own sandbox
                # works via unprivileged user namespaces (no --no-sandbox needed —
                # verified it launches). The launcher/`obsidian://` handler is
                # repointed at this wrapped binary in hosts/linux/omarchy.
                obsidian = let
                  base = prev.obsidian;
                in prev.symlinkJoin {
                  name = "obsidian-nixgl-${base.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "obsidian" ''
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/obsidian "$@"
                    '')
                    base
                  ];
                  meta = base.meta or {};
                  passthru = { unwrapped = base; };
                };
                # openwhispr — local dictation + AI meeting notes, the Linux
                # stand-in for the macOS-only granola cask. Fetched as the
                # upstream release AppImage (see modules/shared/openwhispr.nix).
                # Same GL story as hylo/beeper: wrap bin/openwhispr in nixGLIntel
                # so Chromium/Mesa resolve against system GL on non-NixOS, and
                # force --no-sandbox (the store chrome-sandbox is not setuid).
                # The wrapped `openwhispr` on PATH is what the launcher invokes
                # via xdg.desktopEntries.openwhispr.
                #
                # Vulkan for llama.cpp GPU offload: OpenWhispr's bundled
                # llama-server-vulkan uses a Vulkan loader for local-LLM cleanup,
                # but nixGLIntel only sets up GL (LIBGL/EGL/GBM), NOT a Vulkan
                # ICD — so the loader finds no device and llama.cpp silently
                # falls back to CPU even with --n-gpu-layers 99 (cleanup crawls).
                # Point the loader at Mesa's RADV ICD so it offloads to the AMD
                # iGPU (Strix Halo). The ICD json + libvulkan_radeon.so live in
                # the store (bind-mounted into the AppImage FHS), and /dev/dri is
                # already reachable (GL works). VK_DRIVER_FILES is the modern var,
                # VK_ICD_FILENAMES the legacy fallback; set both.
                openwhispr = let
                  owPkg = prev.callPackage ./modules/shared/openwhispr.nix {};
                  radvIcd = "${prev.mesa}/share/vulkan/icd.d/radeon_icd.x86_64.json";
                in prev.symlinkJoin {
                  name = "openwhispr-nixgl-${owPkg.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "openwhispr" ''
                      export VK_DRIVER_FILES="${radvIcd}"
                      export VK_ICD_FILENAMES="${radvIcd}"
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${owPkg}/bin/openwhispr --no-sandbox "$@"
                    '')
                    owPkg
                  ];
                  meta = owPkg.meta or {};
                  passthru = { unwrapped = owPkg; };
                };
                # Sunshine — Moonlight streaming host (the remote-desktop path
                # into this box from the Mac, over Tailscale). Same GL story as
                # hylo/beeper on non-NixOS: the VAAPI encoder builds its frames
                # through GBM+EGL, and without /run/opengl-driver the stock
                # binary dies at startup with "Couldn't create GBM device: [No
                # such file or directory]" + "Couldn't open EGL display:
                # [0000300C]", so EVERY encoder (even software) fails and
                # Sunshine exits "Unable to find display or encoder". Wrapping
                # bin/sunshine in nixGLIntel resolves Mesa against the system
                # GL (nixGLIntel drives AMD too) and the AMD iGPU then offers
                # h264_vaapi + hevc_vaapi + av1_vaapi.
                #
                # NOTE the companion half of the fix is `capture = wlr` in
                # sunshine.conf (hosts/linux/omarchy) — not something that can
                # be set here. See that file for why it is mandatory.
                sunshine = let
                  base = prev.sunshine;
                in prev.symlinkJoin {
                  name = "sunshine-nixgl-${base.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "sunshine" ''
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/sunshine "$@"
                    '')
                    base
                  ];
                  meta = base.meta or {};
                  passthru = { unwrapped = base; };
                };
                # Zoom (proprietary Qt/CEF app, bwrap-sandboxed in nixpkgs).
                # Same GL story as beeper/stremio/hylo on non-NixOS: wrap
                # bin/zoom in nixGLIntel so Mesa/EGL resolve against system GL
                # (Omarchy has no /run/opengl-driver; nixGLIntel drives AMD too).
                # The bwrap launcher doesn't --clearenv, so nixGL's GL env is
                # inherited by the child that creates the GL context. Zoom.desktop
                # uses a bare `Exec=zoom`, so the wrapped `zoom` on PATH is what
                # the launcher and zoommtg:// join-links invoke — no desktop
                # rewrite needed. Wayland screen-share works via the system
                # xdg-desktop-portal-hyprland.
                zoom-us = let
                  base = prev.zoom-us;
                in prev.symlinkJoin {
                  name = "zoom-us-nixgl-${base.version or "unknown"}";
                  paths = [
                    (prev.writeShellScriptBin "zoom" ''
                      # Force Qt's xcb platform onto EGL. nixGLIntel provides a
                      # working EGL, but Zoom's Qt defaults to GLX, which fails
                      # under XWayland + nix GL ("Could not initialize GLX" ->
                      # ANGLE glXQueryExtensionsString NULL -> SIGABRT). xcb_egl
                      # routes GL context creation through EGL instead and Zoom
                      # starts cleanly.
                      export QT_XCB_GL_INTEGRATION="''${QT_XCB_GL_INTEGRATION:-xcb_egl}"
                      # HiDPI: under XWayland the X screen reports 1x, so Zoom's
                      # Qt UI renders tiny on Omarchy's scale-2 4K panel. Force a
                      # 2x Qt scale to match the compositor (integer scale, so 2
                      # is exact — no blur). Override-able via the env.
                      export QT_SCALE_FACTOR="''${QT_SCALE_FACTOR:-2}"
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/zoom "$@"
                    '')
                    base
                  ];
                  meta = base.meta or {};
                  passthru = { unwrapped = base; };
                };
                # Keyboard-driven GUI navigation (gh:AlfredoSequeida/hints),
                # built from source — not in nixpkgs. See modules/shared/hints.nix.
                hints = prev.callPackage ./modules/shared/hints.nix {};
                # Local Wayland dictation (gh:edwinhu/superwhisper-linux),
                # source via the swlinux-src flake input. See modules/shared/swlinux.nix.
                swlinux = prev.callPackage ./modules/shared/swlinux.nix {
                  src = inputs.swlinux-src;
                };
                # Joy-Con macro pad daemon (gh:edwinhu/joycon-pad) — Linux only.
                # See modules/linux/joycon-pad.nix + the omarchy user service.
                joycon-pad = prev.callPackage ./modules/linux/joycon-pad.nix {
                  src = inputs.joycon-pad-src;
                };

                # Double Commander Qt6 from official releases (aarch64 only; the
                # official release tarball below is arm64. On x86_64 use the stock
                # nixpkgs doublecmd, which builds natively.)
                doublecmd = if !prev.stdenv.hostPlatform.isAarch64 then prev.doublecmd else prev.stdenv.mkDerivation rec {
                  pname = "doublecmd";
                  version = "1.1.32";

                  src = prev.fetchurl {
                    url = "https://github.com/doublecmd/doublecmd/releases/download/v${version}/doublecmd-${version}.qt6.aarch64.tar.xz";
                    hash = "sha256-jf0m/e0wCS/V3nCDPVK+AnD9Qb/FeP3wwuF3g7bJhP0=";
                  };

                  nativeBuildInputs = [
                    prev.makeWrapper
                    prev.autoPatchelfHook
                    prev.qt6.wrapQtAppsHook
                  ];

                  buildInputs = [
                    prev.qt6.qtbase
                    prev.qt6.qtwayland
                    prev.qt6.qtsvg
                    prev.kdePackages.qt6ct
                  ];

                  installPhase = ''
                    runHook preInstall
                    mkdir -p $out/lib/doublecmd $out/bin
                    cp -r * $out/lib/doublecmd/

                    # Remove default settings directory - will use ~/.config/doublecmd
                    rm -rf $out/lib/doublecmd/settings

                    # Wrap with Qt6 environment variables
                    makeWrapper $out/lib/doublecmd/doublecmd $out/bin/doublecmd \
                      --set QT_QPA_PLATFORMTHEME qt6ct \
                      --set QT_QPA_PLATFORM wayland

                    # Install desktop entry
                    mkdir -p $out/share/applications
                    cat > $out/share/applications/doublecmd.desktop <<EOF
[Desktop Entry]
Name=Double Commander
GenericName=File Manager
Comment=Double Commander is a cross platform open source file manager with two panels side by side.
Terminal=false
Icon=$out/share/pixmaps/doublecmd.png
Exec=doublecmd %F
Type=Application
MimeType=inode/directory;
Categories=Utility;FileTools;FileManager;
Keywords=folder;manager;explore;disk;filesystem;orthodox;copy;queue;queuing;operations;
EOF

                    # Install icon
                    mkdir -p $out/share/pixmaps
                    cp $out/lib/doublecmd/pixmaps/mainicon/alt/256px-dcfinal.png $out/share/pixmaps/doublecmd.png

                    runHook postInstall
                  '';

                  meta = with prev.lib; {
                    description = "Two-panel graphical file manager (Qt6)";
                    homepage = "https://doublecmd.sourceforge.io/";
                    license = licenses.gpl2Plus;
                    platforms = [ "aarch64-linux" ];
                  };
                };

                # Beeper for aarch64-linux - extracted AppImage (no FUSE needed).
                # The AppImage below is arm64; on x86_64 wrap stock nixpkgs beeper
                # with nixGLIntel so Mesa resolves against system GL on non-NixOS
                # (Omarchy has no /run/opengl-driver). nixGLIntel drives AMD too.
                beeper = if !prev.stdenv.hostPlatform.isAarch64 then (let
                  # Beeper runs in a bwrap FHS sandbox with no xdg-open and no
                  # host /usr/bin/chromium, so clicking a link was a silent no-op.
                  # Shim xdg-open onto Beeper's PATH: hand the URI to the host's
                  # xdg-desktop-portal OpenURI (reachable via the /run bind +
                  # session bus that bwrap passes through — it does not clearenv),
                  # which opens it in the host default browser. gdbus and the shim
                  # are /nix/store paths, visible inside the sandbox (--bind /nix).
                  xdgOpenShim = prev.writeShellScriptBin "beeper-url-open" ''
                    exec ${prev.glib}/bin/gdbus call --session \
                      --dest org.freedesktop.portal.Desktop \
                      --object-path /org/freedesktop/portal/desktop \
                      --method org.freedesktop.portal.OpenURI.OpenURI \
                      "" "$1" {}
                  '';
                in prev.symlinkJoin {
                  name = "beeper-nixgl-${prev.beeper.version or "unknown"}";
                  paths = [
                    # Shell wrapper wins over prev.beeper/bin/beeper via symlinkJoin
                    # first-path-wins semantics; share/{applications,icons} come
                    # unchanged from prev.beeper.
                    (prev.writeShellScriptBin "beeper" ''
                      # Force TZ into the process that enters beeper's bwrap FHS sandbox.
                      # Beeper's Chromium/ICU can't derive the zone name from the sandbox's
                      # /etc/localtime (symlinked to /.host-etc/localtime, which doesn't match
                      # ICU's .../zoneinfo/ZONE pattern), so it falls back to UTC and shows
                      # timestamps in the wrong tz. Setting TZ makes ICU use its embedded zone
                      # rules directly. Read from /etc/localtime so it tracks tz changes.
                      # (Upstream: NixOS/nixpkgs#505374, dup of #499098.)
                      export TZ="''${TZ:-$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')}"
                      # Beeper's Electron shells out to xdg-open; the FHS ships
                      # its own /usr/bin/xdg-open, which resolves the default
                      # handler to /usr/bin/chromium — absent inside the sandbox —
                      # and fails. For URLs, xdg-open (DE=generic under Hyprland)
                      # falls through to $BROWSER, so point it at a portal shim
                      # that hands the URI to the host xdg-desktop-portal (opens
                      # in the host default browser). Scoped to Beeper's process.
                      export BROWSER="${xdgOpenShim}/bin/beeper-url-open"
                      exec ${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${prev.beeper}/bin/beeper "$@"
                    '')
                    prev.beeper
                  ];
                  meta = prev.beeper.meta or {};
                  passthru = { unwrapped = prev.beeper; };
                }) else (let
                  pname = "beeper";
                  version = "4.2.455";
                  src = prev.fetchurl {
                    url = "https://beeper-desktop.download.beeper.com/builds/Beeper-${version}-arm64.AppImage";
                    hash = "sha256-AYzbKzzwajt60CNJrL02pGyg5wGPPzXxldI7Yg8UzDI=";
                    name = "Beeper-${version}-arm64-v2.AppImage";  # Different name to avoid cache
                  };
                  extracted = prev.appimageTools.extract { inherit pname version src; };
                in prev.appimageTools.wrapType2 {
                  inherit pname version src;
                  extraPkgs = pkgs: with pkgs; [
                    nss
                    nspr
                    # Emoji fonts for the picker
                    noto-fonts-color-emoji
                    twitter-color-emoji
                  ];
                  extraInstallCommands = ''
                    # Add desktop entry and icon from extracted AppImage
                    mkdir -p $out/share/applications $out/share/icons/hicolor/512x512/apps
                    cp ${extracted}/beepertexts.desktop $out/share/applications/ || true
                    cp ${extracted}/beepertexts.png $out/share/icons/hicolor/512x512/apps/beeper.png || true
                  '';
                });
              })
            ];
          };
          modules = [
            agenix.homeManagerModules.default
            inputs.stylix.homeModules.stylix
            ./hosts/linux/${info.host}
            {
              home = {
                username = user;
                homeDirectory = "/home/${user}";
              };
            }
          ];
          extraSpecialArgs = inputs // { inherit user nix-secrets; userInfo = info; };
        }
      ) linuxUsers;
  };
}
