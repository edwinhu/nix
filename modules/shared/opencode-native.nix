{ lib, stdenv, fetchurl, unzip }:

let
  version = "1.1.6";

  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      hash = "sha256-ABnfxLMtY8E5KqJkrtIlPB4ML7CSFvjizCabv7i7SbU=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-ABnfxLMtY8E5KqJkrtIlPB4ML7CSFvjizCabv7i7SbU=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      hash = "sha256-NWS6WLT5IOxbl4CpKy691+dHfS6x+5ozPIAQGbIHjYE=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-t0af5dR3GPKptNuAIfdh/cQbo8XPVZNQ+kY+O2Pgl2k=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "opencode";
  inherit version;

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-${platformInfo.platform}.zip";
    inherit (platformInfo) hash;
  };

  nativeBuildInputs = [ unzip ];

  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  unpackPhase = ''
    unzip $src
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
