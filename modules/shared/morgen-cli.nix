# morgen-cli - CLI and MCP server for Morgen calendar
# Pre-built binary from GitHub releases
{ lib, stdenv, fetchurl }:

let
  version = "0.10.0";

  # Currently only aarch64-darwin (built on M1/M2 Mac)
  # TODO: Add other platforms when cross-compiled
  platforms = {
    aarch64-darwin = {
      hash = "sha256-apoBoKRyG6Cm4/s7HR5Tr7eghWTq/rCVB0WR1v38Qps=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Only aarch64-darwin is currently supported.");

in stdenv.mkDerivation {
  pname = "morgen-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/edwinhu/morgen-cli/releases/download/v${version}/morgen-darwin-arm64";
    inherit (platformInfo) hash;
  };

  dontUnpack = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/morgen
    chmod +x $out/bin/morgen
    runHook postInstall
  '';

  meta = {
    description = "CLI and MCP server for Morgen calendar";
    homepage = "https://github.com/edwinhu/morgen-cli";
    license = lib.licenses.mit;
    mainProgram = "morgen";
    platforms = [ "aarch64-darwin" ];
  };
}
