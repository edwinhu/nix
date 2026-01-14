{ pkgs, lib, ... }:

let
  logseq-dev = pkgs.stdenv.mkDerivation {
    pname = "logseq-dev";
    version = "2.0.0";

    # Source is the local extracted app from GitHub Actions artifact
    # Built from: https://github.com/logseq/logseq/actions/runs/20808349121
    # Artifact: logseq-darwin-arm64-builds (ID: 5059318899)
    src = ../../apps/logseq-dev/Logseq.app;

    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      mkdir -p "$out/Applications"
      cp -r . "$out/Applications/Logseq.app"
    '';

    meta = with lib; {
      description = "Logseq 0.11.x development version from GitHub Actions";
      homepage = "https://github.com/logseq/logseq";
      platforms = platforms.darwin;
    };
  };
in
{
  environment.systemPackages = [ logseq-dev ];
}
