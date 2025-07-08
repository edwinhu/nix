{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
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
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
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
  };

  outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, home-manager, nixpkgs, stylix, agenix, nix-secrets} @inputs:
    let
      # Define user-host mappings
      userHosts = {
        vwh7mb = { 
          system = "aarch64-darwin"; 
          host = "macbook-pro";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
        eh2889 = { 
          system = "x86_64-linux"; 
          host = "rjds";
          fullName = "Edwin Hu";
          email = "eddyhu@gmail.com";
        };
        eddyhu   = { 
          system = "x86_64-linux"; 
          host = "wrds";
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
          exec bash ${self}/apps/${system}/${scriptName}
        '')}/bin/${scriptName}";
      };
      mkLinuxApps = system: {
        "apply" = mkApp "apply" system;
        "build-switch" = mkApp "build-switch" system;
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
        "copy-keys" = mkApp "copy-keys" system;
        "create-keys" = mkApp "create-keys" system;
        "check-keys" = mkApp "check-keys" system;
        "rollback" = mkApp "rollback" system;
      };
    in
    {
      devShells = forAllSystems devShell;
      apps = nixpkgs.lib.genAttrs linuxSystems mkLinuxApps // nixpkgs.lib.genAttrs darwinSystems mkDarwinApps;

      # Darwin configurations for macOS hosts
      darwinConfigurations = let
        darwinUsers = nixpkgs.lib.filterAttrs (user: info: nixpkgs.lib.hasSuffix "darwin" info.system) userHosts;
      in nixpkgs.lib.mapAttrs (user: info:
        darwin.lib.darwinSystem {
          system = info.system;
          specialArgs = inputs // { inherit user nix-secrets; userInfo = info; };
          modules = [
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
