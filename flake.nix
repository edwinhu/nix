{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    emacsmacport = {
      url = "github:railwaycat/homebrew-emacsmacport";
      flake = false;
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
    nix-secrets = {
      url = "git+ssh://git@github.com/edwinhu/nix-secrets.git";
      flake = false;
    };
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zathura-src = {
      url = "github:edwinhu/zathura";
      flake = false;
    };
    zathura-pdf-mupdf-src = {
      url = "github:edwinhu/zathura-pdf-mupdf";
      flake = false;
    };
    clawdbot-skills = {
      url = "path:./clawdbot";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, presmihaylov-taps, dimentium-autoraise, home-manager, nixpkgs, stylix, agenix, nix-secrets, zellij-switch-wasm, emacs-overlay, zathura-src, zathura-pdf-mupdf-src, clawdbot-skills } @inputs:
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
        zathura = with pkgs; mkShell {
          nativeBuildInputs = [
            meson
            ninja
            pkg-config
            gettext
            python3
          ];
          buildInputs = [
            glib
            gtk3
            girara
            sqlite
            file
            json-glib
            curl
            cairo
          ] ++ lib.optionals stdenv.isDarwin [
            gtk-mac-integration
          ];
          shellHook = ''
            echo "Zathura development shell"
            echo "Run: meson setup build && ninja -C build"
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
      mkClaudeUpdateApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Update Claude Code to latest version";
        program = "${(pkgs.writeScriptBin "claude-update" ''
          #!/usr/bin/env bash
          set -euo pipefail

          GREEN='\033[1;32m'
          YELLOW='\033[1;33m'
          RED='\033[1;31m'
          NC='\033[0m'

          NIX_FILE="''$HOME/nix/modules/shared/claude-code-native.nix"
          GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

          CURRENT=$(${pkgs.gnugrep}/bin/grep -oP 'version = "\K[^"]+' "''$NIX_FILE" | head -1)
          LATEST=$(${pkgs.curl}/bin/curl -sfS "''$GCS/latest")
          echo "Current: ''$CURRENT  Latest: ''$LATEST"

          # Quick check: same version → verify local platform hash (catches republished binaries)
          if [ "''$CURRENT" = "''$LATEST" ]; then
            case "$(uname -m)-$(uname -s)" in
              x86_64-Linux)  PLAT=linux-x64;    NIX_KEY=x86_64-linux ;;
              aarch64-Linux) PLAT=linux-arm64;   NIX_KEY=aarch64-linux ;;
              x86_64-Darwin) PLAT=darwin-x64;    NIX_KEY=x86_64-darwin ;;
              *)             PLAT=darwin-arm64;   NIX_KEY=aarch64-darwin ;;
            esac
            REMOTE_SRI=$(${pkgs.nix}/bin/nix store prefetch-file --json "''$GCS/''$LATEST/''$PLAT/claude" 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r '.hash')
            CURRENT_HASH=$(${pkgs.gnugrep}/bin/grep -A2 "''$NIX_KEY" "''$NIX_FILE" | ${pkgs.gnugrep}/bin/grep -oP 'hash = "\K[^"]+')
            if [ "''$CURRENT_HASH" = "''$REMOTE_SRI" ]; then
              echo -e "''${GREEN}Already up to date.''${NC}"
              exit 0
            fi
            echo -e "''${YELLOW}Same version but hash changed, updating...''${NC}"
          fi

          # Prefetch all 4 platforms in parallel
          echo -e "''${YELLOW}Fetching hashes for ''$LATEST...''${NC}"
          HASHDIR=$(mktemp -d)
          trap 'rm -rf "''$HASHDIR"' EXIT

          prefetch() {
            local plat=''$1
            ${pkgs.nix}/bin/nix store prefetch-file --json "''$GCS/''$LATEST/''$plat/claude" 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r '.hash' > "''$HASHDIR/''$plat" \
              || { echo -e "''${RED}Failed: ''$plat''${NC}" >&2; return 1; }
          }

          PIDS=()
          for p in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
            prefetch "''$p" & PIDS+=(''$!)
          done
          for pid in "''${PIDS[@]}"; do wait "''$pid" || exit 1; done

          # Update nix file
          ${pkgs.gnused}/bin/sed -i "s#version = \"[^\"]*\"#version = \"''$LATEST\"#" "''$NIX_FILE"

          for pair in x86_64-linux:linux-x64 aarch64-linux:linux-arm64 x86_64-darwin:darwin-x64 aarch64-darwin:darwin-arm64; do
            nk="''${pair%%:*}" plat="''${pair#*:}" hash=$(cat "''$HASHDIR/''$plat")
            ${pkgs.perl}/bin/perl -i -0pe \
              "s#(''$nk = \\{)[^}]+\\}#\1\n      platform = \"''$plat\";\n      hash = \"''$hash\";\n    }#" \
              "''$NIX_FILE"
          done

          echo -e "''${YELLOW}Building...''${NC}"
          cd "''$HOME/nix"
          CLAUDE_PATH=$(${pkgs.nix}/bin/nix build .#claude-code --print-out-paths --no-link)

          mkdir -p "''$HOME/.local/bin"
          ln -sf "''$CLAUDE_PATH/bin/claude" "''$HOME/.local/bin/claude"

          echo -e "''${GREEN}Updated to ''$LATEST: ~/.local/bin/claude -> ''$CLAUDE_PATH/bin/claude''${NC}"
          echo "Run 'hash -r' or start a new shell to pick it up."
        '')}/bin/claude-update";
      };
      mkOpenCodeUpdateApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Update OpenCode to latest version";
        program = "${(pkgs.writeScriptBin "opencode-update" ''
          #!/usr/bin/env bash
          set -e

          GREEN='\033[1;32m'
          YELLOW='\033[1;33m'
          RED='\033[1;31m'
          NC='\033[0m'

          NATIVE_NIX="$HOME/nix/modules/shared/opencode-native.nix"
          GITHUB_API="https://api.github.com/repos/anomalyco/opencode/releases/latest"
          GITHUB_DL="https://github.com/anomalyco/opencode/releases/download"

          echo -e "''${YELLOW}Fetching latest OpenCode version...''${NC}"
          NEW_VERSION=$(${pkgs.curl}/bin/curl -sS "$GITHUB_API" | ${pkgs.jq}/bin/jq -r '.tag_name' | ${pkgs.gnused}/bin/sed 's/^v//')
          CURRENT_VERSION=$(${pkgs.gnugrep}/bin/grep 'version = ' "$NATIVE_NIX" | head -1 | ${pkgs.gnused}/bin/sed 's/.*"\(.*\)".*/\1/')

          echo "Current version: $CURRENT_VERSION"
          echo "Latest version:  $NEW_VERSION"

          if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
            echo -e "''${GREEN}Already up to date!''${NC}"
            exit 0
          fi

          echo -e "''${YELLOW}Fetching new hashes for all platforms...''${NC}"

          get_sri_hash() {
            local platform=$1
            local ext=$2
            local url="$GITHUB_DL/v$NEW_VERSION/opencode-$platform.$ext"
            echo -e "  Fetching hash for $platform..." >&2
            local hex_hash=$(${pkgs.curl}/bin/curl -sS -L "$url" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
            ${pkgs.nix}/bin/nix hash convert --hash-algo sha256 --to sri "$hex_hash"
          }

          HASH_LINUX_X64=$(get_sri_hash "linux-x64" "tar.gz")
          HASH_LINUX_ARM64=$(get_sri_hash "linux-arm64" "tar.gz")
          HASH_DARWIN_X64=$(get_sri_hash "darwin-x64" "zip")
          HASH_DARWIN_ARM64=$(get_sri_hash "darwin-arm64" "zip")

          echo -e "''${YELLOW}Updating $NATIVE_NIX...''${NC}"

          ${pkgs.perl}/bin/perl -i -0pe 's#version = "[^"]+"#version = "'"$NEW_VERSION"'"#g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's#(x86_64-linux = \{)[^}]+\}#\1\n      platform = "linux-x64";\n      ext = "tar.gz";\n      hash = "'"$HASH_LINUX_X64"'";\n    }#g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's#(aarch64-linux = \{)[^}]+\}#\1\n      platform = "linux-arm64";\n      ext = "tar.gz";\n      hash = "'"$HASH_LINUX_ARM64"'";\n    }#g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's#(x86_64-darwin = \{)[^}]+\}#\1\n      platform = "darwin-x64";\n      ext = "zip";\n      hash = "'"$HASH_DARWIN_X64"'";\n    }#g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's#(aarch64-darwin = \{)[^}]+\}#\1\n      platform = "darwin-arm64";\n      ext = "zip";\n      hash = "'"$HASH_DARWIN_ARM64"'";\n    }#g' "$NATIVE_NIX"

          echo -e "''${YELLOW}Building updated opencode package...''${NC}"
          cd "$HOME/nix"
          OPENCODE_PATH=$(${pkgs.nix}/bin/nix build .#opencode --print-out-paths --no-link)

          echo -e "''${GREEN}OpenCode updated: $OPENCODE_PATH''${NC}"

          mkdir -p "$HOME/.local/bin"
          ln -sf "$OPENCODE_PATH/bin/opencode" "$HOME/.local/bin/opencode"

          echo -e "''${GREEN}Symlink updated: ~/.local/bin/opencode -> $OPENCODE_PATH/bin/opencode''${NC}"
          echo ""
          echo "Run 'hash -r' or start a new shell to use the updated version."
        '')}/bin/opencode-update";
      };
      mkCompanionUpdateApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          themeCss = ./modules/shared/companion-catppuccin.css;
        in {
        type = "app";
        meta.description = "Update the-companion via bun global install";
        program = "${(pkgs.writeScriptBin "companion-update" ''
          #!/usr/bin/env bash
          set -euo pipefail

          GREEN='\033[1;32m'
          YELLOW='\033[1;33m'
          NC='\033[0m'

          BUN="''${HOME}/.bun/bin/bun"
          [ -x "''$BUN" ] || { echo "bun not found at ''$BUN"; exit 1; }

          CURRENT=$(''$BUN pm ls -g 2>/dev/null | grep the-companion | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "none")
          LATEST=$(${pkgs.curl}/bin/curl -s "https://registry.npmjs.org/the-companion/latest" | ${pkgs.jq}/bin/jq -r '.version')
          echo "Current: ''$CURRENT  Latest: ''$LATEST"

          if [ "''$CURRENT" = "''$LATEST" ]; then
            echo -e "''${GREEN}Already up to date.''${NC}"
          else
            echo -e "''${YELLOW}Installing the-companion@''$LATEST...''${NC}"
            ''$BUN install -g the-companion@latest
          fi

          # ── Apply Catppuccin Mocha theme ──
          DIST="''${HOME}/.bun/install/global/node_modules/the-companion/dist"
          [ -d "''$DIST" ] || { echo "dist not found at ''$DIST"; exit 1; }

          echo -e "''${YELLOW}Applying Catppuccin theme...''${NC}"

          # Meta theme color
          ${pkgs.perl}/bin/perl -i -pe 's|<meta name="theme-color" content="#d97757" />|<meta name="theme-color" content="#11111b" media="(prefers-color-scheme: dark)" />\n    <meta name="theme-color" content="#eff1f5" media="(prefers-color-scheme: light)" />|' "''$DIST/index.html"

          # Inject theme CSS before </head>
          ${pkgs.perl}/bin/perl -i -pe 'BEGIN { local $/; open my $f, "<", "'"${themeCss}"'" or die; $css = <$f>; close $f; chomp $css } s|</head>|$css|' "''$DIST/index.html"

          # CSS accent color
          for f in "''$DIST"/assets/index-*.css; do
            ${pkgs.gnused}/bin/sed -i 's/#d97757/#cba6f7/g' "''$f"
          done

          # JS background + font
          for f in "''$DIST"/assets/index-*.js; do
            ${pkgs.gnused}/bin/sed -i 's/#141413/#1e1e2e/g' "''$f"
            ${pkgs.gnused}/bin/sed -i "s/fontFamily:\"monospace\",fontSize:15/fontFamily:\"'Maple Mono NF', monospace\",fontSize:16/g" "''$f"
          done

          # ── Bundle Maple Mono NF fonts ──
          FONT_SRC="''${HOME}/.nix-profile/share/fonts/truetype"
          if [ -d "''$FONT_SRC" ]; then
            mkdir -p "''$DIST/fonts"
            for weight in Regular Bold Italic BoldItalic; do
              cp "''$FONT_SRC/MapleMono-NF-''$weight.ttf" "''$DIST/fonts/" 2>/dev/null || true
            done
            echo "  Fonts bundled"
          else
            echo "  Warning: fonts not found at ''$FONT_SRC (skipping)"
          fi

          # ── Create wrapper in ~/.local/bin ──
          mkdir -p "''${HOME}/.local/bin"
          cat > "''${HOME}/.local/bin/the-companion" <<'WRAPPER'
          #!/bin/bash
          exec "''${HOME}/.bun/bin/the-companion" "$@"
          WRAPPER
          chmod +x "''${HOME}/.local/bin/the-companion"

          VERSION=$(''$BUN pm ls -g 2>/dev/null | grep the-companion | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
          echo -e "''${GREEN}the-companion@''$VERSION ready (themed + fonts)''${NC}"
        '')}/bin/companion-update";
      };
      mkLinuxApps = system: {
        "apply" = mkApp "apply" system;
        "build-switch" = mkApp "build-switch" system;
        "claude-update" = mkClaudeUpdateApp system;
        "opencode-update" = mkOpenCodeUpdateApp system;
        "companion-update" = mkCompanionUpdateApp system;
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
        "claude-update" = mkClaudeUpdateApp system;
        "opencode-update" = mkOpenCodeUpdateApp system;
        "companion-update" = mkCompanionUpdateApp system;
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
        claude-code = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/claude-code-native.nix {};
        gws = (import nixpkgs { inherit system; }).callPackage ./modules/shared/gws.nix {};
        opencode = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/opencode-native.nix {};
        # chrome-for-testing: removed from build to reduce rsync time (338 MB app bundle)
        # chrome-for-testing = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/chrome-for-testing.nix {};
        superhuman-cli = (import nixpkgs { inherit system; }).callPackage ./modules/shared/superhuman-cli.nix {};
        # the-companion: managed by `bun install -g` via `nix run .#companion-update`
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
                emacs-overlay.overlays.default
                (final: prev: {
                  zellij-switch = prev.runCommand "zellij-switch" {} ''
                    mkdir -p $out/share/zellij/plugins
                    cp ${zellij-switch-wasm} $out/share/zellij/plugins/zellij-switch.wasm
                  '';
                  claude-code = prev.callPackage ./modules/shared/claude-code-native.nix {};
                  gws = prev.callPackage ./modules/shared/gws.nix {};
                  opencode = prev.callPackage ./modules/shared/opencode-native.nix {};
                  # chrome-for-testing: removed from overlay to reduce rsync time
                  # chrome-for-testing = prev.callPackage ./modules/shared/chrome-for-testing.nix {};
                  superhuman-cli = prev.callPackage ./modules/shared/superhuman-cli.nix {};
                  # the-companion: managed by `bun install -g` via `nix run .#companion-update`
                  # ast-grep 0.41.0 test_scan_invalid_rule_id fails with "Illegal byte sequence"
                  # on macOS after nixpkgs update to 2026-03-08
                  ast-grep = prev.ast-grep.overrideAttrs (old: {
                    doCheck = false;
                  });
                  zathuraPkgs = prev.zathuraPkgs.overrideScope (zfinal: zprev: {
                    zathura_core = zprev.zathura_core.overrideAttrs (old: {
                      src = zathura-src;
                      version = "2026.02.09-annotations";
                      buildInputs = (old.buildInputs or []) ++ [ prev.curl ];
                    });
                    zathura_pdf_mupdf = zprev.zathura_pdf_mupdf.overrideAttrs (old: {
                      src = zathura-pdf-mupdf-src;
                      version = "0.4.4-annotations";
                      postPatch = (old.postPatch or "") + ''
                        # Remove hardcoded dev include paths that don't exist in nix builds
                        sed -i "/zathura_dev_include = include_directories/d" meson.build
                        sed -i "/include_directories: zathura_dev_include/d" meson.build
                        # Fix girara pkg-config name for new girara
                        sed -i 's/girara-gtk3/girara/g' meson.build
                      '';
                    });
                  });
                  zathura = final.zathuraPkgs.zathuraWrapper.override {
                    plugins = [ final.zathuraPkgs.zathura_pdf_mupdf ];
                  };
                  zathuraApp = prev.stdenv.mkDerivation {
                    pname = "Zathura";
                    version = prev.zathuraPkgs.zathura_core.version;
                    dontUnpack = true;
                    nativeBuildInputs = [ prev.makeWrapper prev.librsvg prev.libicns ];
                    installPhase = ''
                      mkdir -p "$out/Applications/Zathura.app/Contents/MacOS"
                      mkdir -p "$out/Applications/Zathura.app/Contents/Resources"

                      cat > "$out/Applications/Zathura.app/Contents/MacOS/Zathura" <<'SCRIPT'
                      #!/bin/bash
                      export GDK_BACKEND=quartz
                      exec ${final.zathura}/bin/zathura "$@"
                      SCRIPT
                      chmod +x "$out/Applications/Zathura.app/Contents/MacOS/Zathura"

                      for size in 16 32 48 128 256 512 1024; do
                        rsvg-convert -w $size -h $size ${zathura-src}/data/org.pwmt.zathura.svg -o icon_''${size}.png
                      done
                      png2icns "$out/Applications/Zathura.app/Contents/Resources/AppIcon.icns" icon_*.png

                      cat > "$out/Applications/Zathura.app/Contents/Info.plist" <<'PLIST'
                      <?xml version="1.0" encoding="UTF-8"?>
                      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                      <plist version="1.0">
                      <dict>
                        <key>CFBundleExecutable</key>
                        <string>Zathura</string>
                        <key>CFBundleIdentifier</key>
                        <string>org.pwmt.zathura</string>
                        <key>CFBundleName</key>
                        <string>Zathura</string>
                        <key>CFBundleDisplayName</key>
                        <string>Zathura</string>
                        <key>CFBundleIconFile</key>
                        <string>AppIcon</string>
                        <key>CFBundleVersion</key>
                        <string>0.5.8</string>
                        <key>CFBundleShortVersionString</key>
                        <string>0.5.8</string>
                        <key>CFBundlePackageType</key>
                        <string>APPL</string>
                        <key>LSApplicationCategoryType</key>
                        <string>public.app-category.productivity</string>
                        <key>CFBundleDocumentTypes</key>
                        <array>
                          <dict>
                            <key>CFBundleTypeName</key>
                            <string>PDF Document</string>
                            <key>CFBundleTypeRole</key>
                            <string>Viewer</string>
                            <key>LSItemContentTypes</key>
                            <array>
                              <string>com.adobe.pdf</string>
                            </array>
                          </dict>
                        </array>
                      </dict>
                      </plist>
                      PLIST

                      touch "$out/.metadata_never_index"
                      touch "$out/Applications/.metadata_never_index"
                    '';
                  };
                })
              ];
              
              environment.variables = {
                ZELLIJ_SWITCH_PLUGIN = "${pkgs.zellij-switch}/share/zellij/plugins/zellij-switch.wasm";
              };
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
                  "railwaycat/homebrew-emacsmacport" = emacsmacport;
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
              emacs-overlay.overlays.default
              (final: prev: {
                claude-code = prev.callPackage ./modules/shared/claude-code-native.nix {};
                gws = prev.callPackage ./modules/shared/gws.nix {};
                opencode = prev.callPackage ./modules/shared/opencode-native.nix {};
                superhuman-cli = prev.callPackage ./modules/shared/superhuman-cli.nix {};
                # the-companion: managed by `bun install -g` via `nix run .#companion-update`

                # Double Commander Qt6 from official releases
                doublecmd = prev.stdenv.mkDerivation rec {
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

                zathuraPkgs = prev.zathuraPkgs.overrideScope (zfinal: zprev: {
                  zathura_core = zprev.zathura_core.overrideAttrs (old: {
                    src = zathura-src;
                    version = "2026.02.09-annotations";
                    buildInputs = (old.buildInputs or []) ++ [ prev.curl ];
                  });
                  zathura_pdf_mupdf = zprev.zathura_pdf_mupdf.overrideAttrs (old: {
                    src = zathura-pdf-mupdf-src;
                    version = "0.4.4-annotations";
                    postPatch = (old.postPatch or "") + ''
                      # Remove hardcoded dev include paths that don't exist in nix builds
                      sed -i "/zathura_dev_include = include_directories/d" meson.build
                      sed -i "/include_directories: zathura_dev_include/d" meson.build
                      # Fix girara pkg-config name for new girara
                      sed -i 's/girara-gtk3/girara/g' meson.build
                    '';
                  });
                });
                zathura = final.zathuraPkgs.zathuraWrapper.override {
                  plugins = [ final.zathuraPkgs.zathura_pdf_mupdf ];
                };

                # Beeper for aarch64-linux - extracted AppImage (no FUSE needed)
                beeper = let
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
                };
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