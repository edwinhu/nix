{ lib, stdenv, fetchurl, unzip, gnutar, gzip }:

let
  version = "1.1.64";

  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      ext = "tar.gz";
      hash = "sha256-RINJCXzpPZbl0ieUD95U9x//DUdssrFnJBfv2pKlfB4=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      ext = "tar.gz";
      hash = "sha256-brUpjRZvd6Fj18jJ6Cu/6ll+JuMNLFZ4kzQ5NYkv2UY=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      ext = "zip";
      hash = "sha256-ShokyXTUcNWGJJddimqoWJFN95Q9vRDU/gy7A3t1XGM=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      ext = "zip";
      hash = "sha256-egB7GW5ptTPD5v5B0wy2AAuTtM93yp3WxR3mSCscd3Y=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "opencode";
  inherit version;

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-${platformInfo.platform}.${platformInfo.ext}";
    inherit (platformInfo) hash;
  };

  nativeBuildInputs = if platformInfo.ext == "zip" then [ unzip ] else [ gnutar gzip ];

  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  unpackPhase = if platformInfo.ext == "zip" then ''
    unzip $src
  '' else ''
    tar xzf $src
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp opencode $out/bin/opencode
    chmod +x $out/bin/opencode
    runHook postInstall
  '';

  meta = {
    description = "OpenCode - AI coding agent for the terminal";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    platforms = lib.attrNames platforms;
    mainProgram = "opencode";
  };
}
