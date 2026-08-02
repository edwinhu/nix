{ pkgs }:

let
  version = "0.1.0";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-VWFWw2dFpK+JiWq+LGtH5JWpp8FGUl3ZVQhfys5pr4k=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-cln6+1QqjjAfN8eQw6B4Z3PC+mqOzFQjqdQHMkMGvYM=";
    };
  };

  sys = systemMap.${pkgs.stdenv.hostPlatform.system} or (throw "Unsupported system: ${pkgs.stdenv.hostPlatform.system}");
  
in pkgs.stdenv.mkDerivation {
  pname = "consensus";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/edwinhu/consensus-cli/releases/download/v${version}/consensus-${sys.os}-${sys.arch}";
    hash = sys.hash;
  };

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/consensus
    chmod +x $out/bin/consensus
  '';

  meta = with pkgs.lib; {
    description = "Consensus CLI";
    homepage = "https://github.com/edwinhu/consensus-cli";
    mainProgram = "consensus";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
