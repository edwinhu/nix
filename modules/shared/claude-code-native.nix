# Native Claude Code binary package
# Uses pre-built binaries from Anthropic instead of npm
{ lib, stdenv, fetchurl }:

let
  version = "2.1.69";

  # Platform-specific binary sources
  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      hash = "sha256-s729Wjy/jKr+NTAiFw33f++oCwAAMHTU0n59qMWeYpo=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-7Me78QUT/xIjJ4ZuuXISlFtzr9f4HjBwA3XN8Q9QsqM=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      hash = "sha256-5Zh7TdUCplQr+Gw8C80dUzt3Rhb8fUlWbOCyBA5sE3Q=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-qG4U9EsWfB6Nv3ZPdnVbkuz1LAl9cyo0Yf5ltftgvgU=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/${platformInfo.platform}/claude";
    inherit (platformInfo) hash;
  };

  # Don't use autoPatchelfHook - it corrupts the embedded executable
  # The binary works fine on standard glibc systems without patching
  nativeBuildInputs = [ ];
  buildInputs = [ ];

  dontUnpack = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/claude
    chmod +x $out/bin/claude
    runHook postInstall
  '';

  meta = {
    description = "Claude Code - Anthropic's official CLI for Claude";
    homepage = "https://claude.ai/code";
    license = lib.licenses.unfree;
    platforms = lib.attrNames platforms;
    mainProgram = "claude";
  };
}
