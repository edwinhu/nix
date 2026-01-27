# Native Claude Code binary package
# Uses pre-built binaries from Anthropic instead of npm
{ lib, stdenv, fetchurl }:

let
  version = "2.1.20";

  # Platform-specific binary sources
  platforms = {
    x86_64-linux = {
      platform = "linux-x64";
      hash = "sha256-+dNpj1N4pIbbLU7qXID5XCzrQQ+86p/8VwO1qslXT8w=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-64gBx6SoUBshwjXzZnTxcyjmXnls+KYZazv5ojrhb5k=";
    };
    x86_64-darwin = {
      platform = "darwin-x64";
      hash = "sha256-DTgpJ3DIi9mxOwaEr7DS3AAooUN9DAm+NEnSs9NpsEU=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-xXA1lu2FSujld1zzjeXXHYpW7P4/NpBIEocOnjQXjIw=";
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
