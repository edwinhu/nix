# Native Claude Code binary package
# Uses pre-built binaries from Anthropic instead of npm
{ lib, stdenv, fetchurl }:

let
  version = "2.1.70";

  # Platform-specific binary sources
  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      hash = "sha256-HlwQEeyJnvDKnwgRwTw+1EQ3Qirtha9gDV/lB0b6rx0=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-JkxmnOR0C7SJawesARAZC89hjt3U+wBos/4s6YlzRoI=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      hash = "sha256-M4dV3OWlyZQZ83vo3UJEEMNfxHb32Mys2e1+8zuEc64=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-YYHlC8mkGF825UN0TSVrdA4N+jw/3PHQS3g4eytGZ4E=";
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
