# Native Claude Code binary package
# Uses pre-built binaries from Anthropic instead of npm
{ lib, stdenv, fetchurl }:

let
  version = "2.1.86";

  # Platform-specific binary sources
  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      hash = "sha256-rc4CxflKhbbKIxyK7vUzcHWXzTh+iTR3ZFW4fRCjBRs=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-wErr494UBnm0zOFYgS1vARt+nEg0lsywRyzzjMFxSv4=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      hash = "sha256-3pb2lmZI7Nk8NF+rSzvpROk7pBQPHNp/5F/+2TEztn4=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-dvr+6ZUml4Sxv4C1FMOzVDlCiPt5S+0B7yAWiHTgiOo=";
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
