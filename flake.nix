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
  };

  outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, presmihaylov-taps, home-manager, nixpkgs, stylix, agenix, nix-secrets, zellij-switch-wasm, emacs-overlay, zathura-src, zathura-pdf-mupdf-src } @inputs:
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
          exec bash ${self}/apps/${system}/${scriptName}
        '')}/bin/${scriptName}";
        meta.description = "Run ${scriptName} for ${system}";
      };
      mkClaudeUpdateApp = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          platformMap = {
            "x86_64-linux" = "linux-x64";
            "aarch64-linux" = "linux-arm64";
            "x86_64-darwin" = "darwin-x64";
            "aarch64-darwin" = "darwin-arm64";
          };
        in {
        type = "app";
        meta.description = "Update Claude Code to latest version";
        program = "${(pkgs.writeScriptBin "claude-update" ''
          #!/usr/bin/env bash
          set -e

          GREEN='\033[1;32m'
          YELLOW='\033[1;33m'
          RED='\033[1;31m'
          NC='\033[0m'

          NATIVE_NIX="$HOME/nix/modules/shared/claude-code-native.nix"
          GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

          echo -e "''${YELLOW}Fetching latest Claude Code version...''${NC}"
          NEW_VERSION=$(${pkgs.curl}/bin/curl -sS "$GCS_BUCKET/latest")
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
            local hex_hash=$(${pkgs.curl}/bin/curl -sS "$GCS_BUCKET/$NEW_VERSION/$platform/claude" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
            ${pkgs.nix}/bin/nix hash convert --hash-algo sha256 --to sri "$hex_hash"
          }

          HASH_LINUX_X64=$(get_sri_hash "linux-x64")
          HASH_LINUX_ARM64=$(get_sri_hash "linux-arm64")
          HASH_DARWIN_X64=$(get_sri_hash "darwin-x64")
          HASH_DARWIN_ARM64=$(get_sri_hash "darwin-arm64")

          echo -e "''${YELLOW}Updating $NATIVE_NIX...''${NC}"

          ${pkgs.gnused}/bin/sed -i \
            -e "s/version = \"$CURRENT_VERSION\"/version = \"$NEW_VERSION\"/" \
            -e "s|x86_64-linux = {|x86_64-linux = {\n      platform = \"linux-x64\";\n      hash = \"$HASH_LINUX_X64\";\n    };|" \
            "$NATIVE_NIX"

          # Use perl for more reliable multi-line replacement
          ${pkgs.perl}/bin/perl -i -0pe "s/version = \"[^\"]+\"/version = \"$NEW_VERSION\"/g" "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's/(x86_64-linux = \{)[^}]+\}/\1\n      platform = "linux-x64";\n      hash = "'"$HASH_LINUX_X64"'";\n    }/g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's/(aarch64-linux = \{)[^}]+\}/\1\n      platform = "linux-arm64";\n      hash = "'"$HASH_LINUX_ARM64"'";\n    }/g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's/(x86_64-darwin = \{)[^}]+\}/\1\n      platform = "darwin-x64";\n      hash = "'"$HASH_DARWIN_X64"'";\n    }/g' "$NATIVE_NIX"
          ${pkgs.perl}/bin/perl -i -0pe 's/(aarch64-darwin = \{)[^}]+\}/\1\n      platform = "darwin-arm64";\n      hash = "'"$HASH_DARWIN_ARM64"'";\n    }/g' "$NATIVE_NIX"

          echo -e "''${YELLOW}Building updated claude-code package...''${NC}"
          cd "$HOME/nix"
          CLAUDE_PATH=$(${pkgs.nix}/bin/nix build .#claude-code --print-out-paths --no-link)

          echo -e "''${GREEN}Claude Code updated: $CLAUDE_PATH''${NC}"

          mkdir -p "$HOME/.local/bin"
          ln -sf "$CLAUDE_PATH/bin/claude" "$HOME/.local/bin/claude"

          echo -e "''${GREEN}Symlink updated: ~/.local/bin/claude -> $CLAUDE_PATH/bin/claude''${NC}"
          echo ""
          echo "Run 'hash -r' or start a new shell to use the updated version."
        '')}/bin/claude-update";
      };
      mkLinuxApps = system: {
        "apply" = mkApp "apply" system;
        "build-switch" = mkApp "build-switch" system;
        "claude-update" = mkClaudeUpdateApp system;
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
        "copy-keys" = mkApp "copy-keys" system;
        "create-keys" = mkApp "create-keys" system;
        "check-keys" = mkApp "check-keys" system;
        "rollback" = mkApp "rollback" system;
      };
    in
    {
      devShells = forAllSystems devShell;
      apps = nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

      # Expose claude-code as a package for quick updates without full rebuild
      packages = forAllSystems (system: {
        claude-code = (import nixpkgs { inherit system; config.allowUnfree = true; }).callPackage ./modules/shared/claude-code-native.nix {};
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
                  opencode = prev.callPackage ./modules/shared/opencode-native.nix {};
                  zathuraPkgs = prev.zathuraPkgs.overrideScope (zfinal: zprev: {
                    zathura_core = zprev.zathura_core.overrideAttrs (old: {
                      src = zathura-src;
                      version = "0.5.8-annotations";
                      buildInputs = (old.buildInputs or []) ++ [ prev.curl ];
                    });
                    zathura_pdf_mupdf = zprev.zathura_pdf_mupdf.overrideAttrs (old: {
                      src = zathura-pdf-mupdf-src;
                      version = "0.4.4-annotations";
                      postPatch = (old.postPatch or "") + ''
                        # Remove hardcoded dev include paths that don't exist in nix builds
                        sed -i "/zathura_dev_include = include_directories/d" meson.build
                        sed -i "/include_directories: zathura_dev_include/d" meson.build
                      '';
                    });
                  });
                  zathura = final.zathuraPkgs.zathuraWrapper.override {
                    plugins = [ final.zathuraPkgs.zathura_pdf_mupdf ];
                  };
                  zathuraApp = prev.stdenv.mkDerivation {
                    pname = "Zathura";
                    version = "0.5.8";
                    dontUnpack = true;
                    nativeBuildInputs = [ prev.makeWrapper prev.librsvg prev.libicns ];
                    installPhase = ''
                      mkdir -p "$out/Applications/Zathura.app/Contents/MacOS"
                      mkdir -p "$out/Applications/Zathura.app/Contents/Resources"

                      # Create the executable wrapper with HiDPI support
                      cat > "$out/Applications/Zathura.app/Contents/MacOS/Zathura" <<'SCRIPT'
                      #!/bin/bash
                      export GDK_BACKEND=quartz
                      exec ${final.zathura}/bin/zathura "$@"
                      SCRIPT
                      chmod +x "$out/Applications/Zathura.app/Contents/MacOS/Zathura"

                      # Create icns icon from SVG using png2icns
                      for size in 16 32 48 128 256 512 1024; do
                        rsvg-convert -w $size -h $size ${zathura-src}/data/org.pwmt.zathura.svg -o icon_''${size}.png
                      done
                      png2icns "$out/Applications/Zathura.app/Contents/Resources/AppIcon.icns" icon_*.png

                      # Create Info.plist with PDF handler registration and icon
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
      in nixpkgs.lib.mapAttrs (user: info:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = info.system;
            config.allowUnfree = true;
            overlays = [
              emacs-overlay.overlays.default
              (final: prev: {
                claude-code = prev.callPackage ./modules/shared/claude-code-native.nix {};
                opencode = prev.callPackage ./modules/shared/opencode-native.nix {};
                zathuraPkgs = prev.zathuraPkgs.overrideScope (zfinal: zprev: {
                  zathura_core = zprev.zathura_core.overrideAttrs (old: {
                    src = zathura-src;
                    version = "0.5.8-annotations";
                    buildInputs = (old.buildInputs or []) ++ [ prev.curl ];
                  });
                  zathura_pdf_mupdf = zprev.zathura_pdf_mupdf.overrideAttrs (old: {
                    src = zathura-pdf-mupdf-src;
                    version = "0.4.4-annotations";
                    postPatch = (old.postPatch or "") + ''
                      # Remove hardcoded dev include paths that don't exist in nix builds
                      sed -i "/zathura_dev_include = include_directories/d" meson.build
                      sed -i "/include_directories: zathura_dev_include/d" meson.build
                    '';
                  });
                });
                zathura = final.zathuraPkgs.zathuraWrapper.override {
                  plugins = [ final.zathuraPkgs.zathura_pdf_mupdf ];
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