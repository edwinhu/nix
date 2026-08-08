{ pkgs }:

let
  version = "0.1.2";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-Xn8d/ZOrDDEqTquRs75WluDIAMsEctiuLqo1J9rfNnM=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-2EKskZlo8y8iaxv9eB1p2qIjDgFtuZM2aaSM3thN+GM=";
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
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
