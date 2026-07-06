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
    clawdbot-skills = {
      url = "path:./clawdbot";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    seance = {
      url = "git+https://github.com/no1msd/seance?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, presmihaylov-taps, barutsrb-tap, dimentium-autoraise, home-manager, nixpkgs, nixpkgs-onlyoffice, stylix, agenix, nix-secrets, zellij-switch-wasm, emacs-overlay, clawdbot-skills, seance } @inputs:
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
        meta.description = "Bootstrap-install claude, codex, opencode, happy, happy-agent, agy (idempotent)";
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
        meta.description = "Force-reinstall claude, codex, opencode, happy, happy-agent, agy to latest";
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
        happy-app = (import nixpkgs { inherit system; }).callPackage ./modules/shared/happy-app.nix {};
        # elio via newer nixpkgs: the main lock's cargo vendor fetcher sends
        # no User-Agent and crates.io now 403s it (affects all platforms).
        elio = (import inputs.nixpkgs-onlyoffice { inherit system; }).callPackage ./modules/shared/elio.nix {};
        revdiff = (import nixpkgs { inherit system; }).callPackage ./modules/shared/revdiff.nix {};
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
                  morgen-cli = prev.callPackage ./modules/shared/morgen-cli.nix {};
                  happy-app = prev.callPackage ./modules/shared/happy-app.nix {};
                  # elio via newer nixpkgs: the main lock's cargo vendor fetcher
                  # sends no User-Agent and crates.io now 403s it.
                  elio = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/elio.nix {};
                  revdiff = prev.callPackage ./modules/shared/revdiff.nix {};
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
                morgen-cli = prev.callPackage ./modules/shared/morgen-cli.nix {};
                # elio via newer nixpkgs: the main lock's cargo vendor fetcher
                # sends no User-Agent and crates.io now 403s it.
                elio = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/elio.nix {};
                revdiff = prev.callPackage ./modules/shared/revdiff.nix {};
                onlyoffice-x2t = prev.callPackage ./modules/shared/onlyoffice-x2t.nix {};
                onlyoffice-docbuilder = (import inputs.nixpkgs-onlyoffice { system = prev.stdenv.hostPlatform.system; }).callPackage ./modules/shared/onlyoffice/docbuilder.nix {};
                seance = seance.packages.${prev.system}.seance;

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
