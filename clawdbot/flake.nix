{
  description = "Clawdbot skills dependencies (mcporter, summarize, whisper)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

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
              mcporter
              summarize
              pkgs.openai-whisper
            ];
          };

          inherit mcporter summarize;
        };

        # Development shell with all tools
        devShells.default = pkgs.mkShell {
          buildInputs = [
            mcporter
            summarize
            pkgs.openai-whisper
            pkgs.nodejs
            pkgs.python3
          ];
        };
      }
    );
}
