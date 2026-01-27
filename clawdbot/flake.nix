{
  description = "Clawdbot skills dependencies (gog, mcporter, obsidian-cli, summarize, whisper)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # GOG CLI - Google Workspace CLI
        gogcli = pkgs.buildGoModule rec {
          pname = "gog";
          version = "0.9.0";

          src = pkgs.fetchFromGitHub {
            owner = "steipete";
            repo = "gogcli";
            rev = "v${version}";
            hash = "sha256-DXRw5jf/5fC8rgwLIy5m9qkxy3zQNrUpVG5C0RV7zKM=";
          };

          vendorHash = "sha256-nig3GI7eM1XRtIoAh1qH+9PxPPGynl01dCZ2ppyhmzU=";

          doCheck = false; # Tests require OAuth

          meta = with pkgs.lib; {
            description = "Google Workspace CLI for Gmail, Calendar, Drive, Contacts, Sheets, and Docs";
            homepage = "https://gogcli.sh";
            license = licenses.mit;
          };
        };

        # Obsidian CLI
        obsidian-cli = pkgs.buildGoModule rec {
          pname = "obsidian-cli";
          version = "0.2.2";

          src = pkgs.fetchFromGitHub {
            owner = "Yakitrak";
            repo = "obsidian-cli";
            rev = "v${version}";
            hash = "sha256-H7Nm+QwpAD5K1Ltl4irvSI/z3Ct7g3rh2w0Rbka7LwE=";
          };

          vendorHash = null; # Project includes vendor folder

          doCheck = false; # Skip tests

          meta = with pkgs.lib; {
            description = "CLI for automating Obsidian vaults";
            homepage = "https://github.com/Yakitrak/obsidian-cli";
            license = licenses.mit;
          };
        };

        # Summarize - fetch pre-built binary
        summarize = pkgs.stdenv.mkDerivation rec {
          pname = "summarize";
          version = "0.10.0";

          src = pkgs.fetchurl {
            url = "https://github.com/steipete/summarize/releases/download/v${version}/summarize-macos-arm64-v${version}.tar.gz";
            hash = "sha256-CUDf/Qe3YAU71pkEFA1x+nRsxmM4nzECy8Bo3EzgnWY=";
          };

          sourceRoot = ".";

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            mkdir -p $out/bin
            cp summarize $out/bin/
            chmod +x $out/bin/summarize
          '';

          meta = with pkgs.lib; {
            description = "Summarize URLs, podcasts, and local files";
            homepage = "https://summarize.sh";
            license = licenses.mit;
          };
        };

        # MCPorter - MCP server CLI tool
        mcporter = pkgs.stdenv.mkDerivation rec {
          pname = "mcporter";
          version = "0.7.3";

          src = pkgs.fetchurl {
            url = "https://github.com/steipete/mcporter/releases/download/v${version}/mcporter-macos-arm64-v${version}.tar.gz";
            hash = "sha256-hS2ore/reN9TcFqjrxL+clBnyAFKWlfR1qOyc9Kaff4=";
          };

          sourceRoot = ".";

          dontBuild = true;
          dontConfigure = true;

          installPhase = ''
            mkdir -p $out/bin
            cp mcporter $out/bin/
            chmod +x $out/bin/mcporter
          '';

          meta = with pkgs.lib; {
            description = "Call MCP servers via TypeScript API or CLI";
            homepage = "https://mcporter.dev";
            license = licenses.mit;
          };
        };

      in
      {
        packages = {
          default = self.packages.${system}.clawdbot-skills;

          # Bundle all skill dependencies
          clawdbot-skills = pkgs.buildEnv {
            name = "clawdbot-skills";
            paths = [
              gogcli
              mcporter
              obsidian-cli
              summarize
              pkgs.openai-whisper
            ];
          };

          inherit gogcli mcporter obsidian-cli summarize;
        };

        # Development shell with all tools
        devShells.default = pkgs.mkShell {
          buildInputs = [
            gogcli
            mcporter
            obsidian-cli
            summarize
            pkgs.openai-whisper
            pkgs.nodejs
            pkgs.python3
          ];
        };
      }
    );
}
