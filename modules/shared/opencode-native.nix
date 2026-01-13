{ lib, stdenv, fetchurl, unzip, gnutar, gzip }:

let
  version = "1.1.17";

  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      ext = "tar.gz";
      hash = "sha256-q7v34mXvE+kWkmXKkdn1cUrq3Yh57uy2ULNR/iooDm8=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      ext = "tar.gz";
      hash = "sha256-LiY58ZpXAOkv9ouDITobFsccbBHHEf7MWlAm4TIdEaI=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      ext = "zip";
      hash = "sha256-1Emg57OckBYtRPuVBoj8nkyTMo16knqjVOJMu7gXx/o=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      ext = "zip";
      hash = "sha256-ZHLf0VspJYTWTean5VGqHEhtQZeIDCRTJ07Va0YoISk=";
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
