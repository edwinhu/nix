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
    barutsrb-tap = {
      url = "github:BarutSRB/homebrew-tap";
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

  outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, presmihaylov-taps, barutsrb-tap, dimentium-autoraise, home-manager, nixpkgs, stylix, agenix, nix-secrets, zellij-switch-wasm, emacs-overlay, zathura-src, zathura-pdf-mupdf-src, clawdbot-skills } @inputs:
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
      mkSetupAiToolsApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
        type = "app";
        meta.description = "Bootstrap-install claude, codex, opencode, the-companion (idempotent)";
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
        meta.description = "Force-reinstall claude, codex, opencode, the-companion to latest";
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
          sudo chown -R "$(whoami)" /Applications/Claude.app

          echo -e "''${GREEN}Updated Claude Desktop to ''$LATEST''${NC}"
          echo "Opening Claude Desktop..."
          open -a Claude
        '')}/bin/claude-desktop-update";
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
          [ -x "''$BUN" ] || BUN="''${HOME}/.nix-profile/bin/bun"
          [ -x "''$BUN" ] || { echo "bun not found"; exit 1; }

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
        "setup-ai-tools" = mkSetupAiToolsApp system;
        "update-ai-tools" = mkUpdateAiToolsApp system;
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
        "setup-ai-tools" = mkSetupAiToolsApp system;
        "update-ai-tools" = mkUpdateAiToolsApp system;
        "claude-desktop-update" = mkClaudeDesktopUpdateApp system;
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
        gws = (import nixpkgs { inherit system; }).callPackage ./modules/shared/gws.nix {};
        # chrome-for-testing: removed from build to reduce rsync time (338 MB app bundle)
        # chrome-for-testing = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/chrome-for-testing.nix {};
        superhuman-cli = (import nixpkgs { inherit system; }).callPackage ./modules/shared/superhuman-cli.nix {};
        companion-app = (import nixpkgs { inherit system; }).callPackage ./modules/shared/companion-app.nix {};
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
                  gws = prev.callPackage ./modules/shared/gws.nix {};
                  # chrome-for-testing: removed from overlay to reduce rsync time
                  # chrome-for-testing = prev.callPackage ./modules/shared/chrome-for-testing.nix {};
                  superhuman-cli = prev.callPackage ./modules/shared/superhuman-cli.nix {};
                  companion-app = prev.callPackage ./modules/shared/companion-app.nix {};
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
                  "barutsrb/homebrew-tap" = barutsrb-tap;
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
                gws = prev.callPackage ./modules/shared/gws.nix {};
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
