# Google Workspace CLI
# Pre-built binaries from https://github.com/googleworkspace/cli
{ lib, stdenv, fetchurl, autoPatchelfHook }:

let
  version = "0.4.4";

  platforms = {
    x86_64-linux = {
      platform = "x86_64-unknown-linux-gnu";
      hash = "sha256-ZRwXENjHleC2tOS5UMdVQMIyJLtcsnLp0NwuMKm+iFU=";
    };
    aarch64-linux = {
      platform = "aarch64-unknown-linux-gnu";
      hash = "sha256-e56mRMIM/IrI1Yz1KzVo6Jm8GMHtU28kHCU9ST85dT8=";
    };
    x86_64-darwin = {
      platform = "x86_64-apple-darwin";
      hash = "sha256-4GUZPcwJ684m2S1q01lW3Z86uJacIw8GX7P6iOOdWXE=";
    };
    aarch64-darwin = {
      platform = "aarch64-apple-darwin";
      hash = "sha256-483dX6mZIvMBSKBZv98tFbOejpVkDs0DPQkY6MzIAQo=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "gws";
  inherit version;

  src = fetchurl {
    url = "https://github.com/googleworkspace/cli/releases/download/v${version}/gws-${platformInfo.platform}.tar.gz";
    inherit (platformInfo) hash;
  };

  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp gws $out/bin/gws
    chmod +x $out/bin/gws
    runHook postInstall
  '';

  meta = {
    description = "Google Workspace CLI - command-line interface for Google Workspace APIs";
    homepage = "https://github.com/googleworkspace/cli";
    license = lib.licenses.asl20;
    platforms = lib.attrNames platforms;
    mainProgram = "gws";
  };
}
