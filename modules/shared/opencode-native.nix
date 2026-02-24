{ lib, stdenv, fetchurl, unzip, gnutar, gzip }:

let
  version = "1.2.10";

  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      ext = "tar.gz";
      hash = "sha256-68wkAS6PBnsQ10FkMMiOnEKRFez7zPjanrWds7Ypo1g=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      ext = "tar.gz";
      hash = "sha256-2anU8Lwe0kYljA6IRugFk3Vacr9K/TlAxAcdbwt7d3U=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      ext = "zip";
      hash = "sha256-HZQZbvEZ6WXVcZLc4hJJCoGaSNY8+JyQxoFZ15Ct4Gc=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      ext = "zip";
      hash = "sha256-rYgGZLawEs2u/E0XWpav7zlcSBuTKMjrXbFDqGRK0dk=";
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
