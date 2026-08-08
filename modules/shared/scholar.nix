{ pkgs }:

let
  version = "0.1.2";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-Sv/Wu1PadFhaaxPAVij4HyyR/i8iwjpgt8/+daDRL+M=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-B34nRfIe5hjgB3/o0jaslS6sbAVJCVS4tRkVToJXLEM=";
    };
  };

  sys = systemMap.${pkgs.stdenv.hostPlatform.system} or (throw "Unsupported system: ${pkgs.stdenv.hostPlatform.system}");
  
in pkgs.stdenv.mkDerivation {
  pname = "scholar";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/edwinhu/google-scholar-cli/releases/download/v${version}/scholar-${sys.os}-${sys.arch}";
    hash = sys.hash;
  };

  dontUnpack = true;

  # `bun build --compile` appends the bundled entrypoint to the bun runtime.
  # strip/patchelf discard it, leaving a bare bun that prints its own help.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/scholar
    chmod +x $out/bin/scholar
  '';

  meta = with pkgs.lib; {
    description = "Google Scholar CLI";
    homepage = "https://github.com/edwinhu/google-scholar-cli";
    mainProgram = "scholar";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
