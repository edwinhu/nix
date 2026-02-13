# superhuman-cli - CLI and MCP server for Superhuman email
# Pre-built binary from GitHub releases
{ lib, stdenv, fetchurl }:

let
  version = "0.2.2";

  # Currently only aarch64-darwin (built on M1/M2 Mac)
  # TODO: Add other platforms when cross-compiled
  platforms = {
    aarch64-darwin = {
      hash = "sha256-VY2pvLYDZ2J5uobBAYJwA3FTPFGOixThVmDBTW6PWIA=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Only aarch64-darwin is currently supported.");

in stdenv.mkDerivation {
  pname = "superhuman-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/edwinhu/superhuman-cli/releases/download/v${version}/superhuman-${version}";
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
    cp $src $out/bin/superhuman
    chmod +x $out/bin/superhuman
    runHook postInstall
  '';

  meta = {
    description = "CLI and MCP server for Superhuman email";
    homepage = "https://github.com/edwinhu/superhuman-cli";
    license = lib.licenses.mit;
    mainProgram = "superhuman";
    platforms = [ "aarch64-darwin" ];
  };
}
