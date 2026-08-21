{ pkgs }:

let
  version = "0.2.0";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-nIKV5UcTg+AjKecjOPEyQx+ib2nayyLtm8mnalp7xYc=";
    };
    "aarch64-linux" = {
      os = "linux";
      arch = "arm64";
      hash = "sha256-B9IDox030A05nJI6dqi281ljY6k4Pamo4cJtx95B/so=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-oK/7exhJKg8jFuT/5XOYWRRiZtd3uZoPD0A4I3Mg4Fg=";
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
    platforms = builtins.attrNames systemMap;
  };
}
