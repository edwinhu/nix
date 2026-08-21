{ pkgs }:

let
  version = "0.2.0";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-uJ2C3J93SURO3PBgWiNF4ETpGyQnYZIsYdxdfH8RhW4=";
    };
    "aarch64-linux" = {
      os = "linux";
      arch = "arm64";
      hash = "sha256-ney1BWI20inNcnh6h78+r4VS0SMk6DnrY96mMqMkl08=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-wgkdthoq/KgW6OFxrykGzyL02369G1u0TTO+QNc17/k=";
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

  # `bun build --compile` appends the bundled entrypoint to the bun runtime.
  # strip/patchelf discard it, leaving a bare bun that prints its own help.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/consensus
    chmod +x $out/bin/consensus
  '';

  meta = with pkgs.lib; {
    description = "Consensus CLI";
    homepage = "https://github.com/edwinhu/consensus-cli";
    mainProgram = "consensus";
    platforms = builtins.attrNames systemMap;
  };
}
