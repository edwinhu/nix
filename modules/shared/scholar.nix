{ pkgs }:

let
  version = "0.1.3";
  
  systemMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "x64";
      hash = "sha256-O3ZzJtv9dqFStMNHm1ORM0JsBFra168IgGH4Kk5TvjU=";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
      hash = "sha256-fFc9+qkmspUV2sMhZQXCXvghzYOyij/sZTF6GqyHSMY=";
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
