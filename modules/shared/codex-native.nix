# Native OpenAI Codex CLI binary package
# Uses pre-built release tarballs from github.com/openai/codex
{ lib, stdenv, fetchurl, gnutar, gzip }:

let
  version = "0.121.0";

  # Platform-specific binary sources
  platforms = {
    x86_64-linux = {
      target = "x86_64-unknown-linux-gnu";
      hash = "sha256-8FOsgenGdpkg+e41ZqutR6sIVut+55JChoFmTs4RNDA=";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-gnu";
      hash = "sha256-nOXt1VJImK0ulbWfJ4l34xJybgWHlX0fEO44kHD+UDQ=";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hash = "sha256-lOa6ilUtRiW+7oV/UT+xK8IOVguUJ8SpNzPb2GYZ9BU=";
    };
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-YPcDnmOn3orkdBNqxvWT7BqRPh3coN9ZreH21utff9A=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${platformInfo.target}.tar.gz";
    inherit (platformInfo) hash;
  };

  # Don't patchelf the binary — works on standard glibc systems without patching
  # (matches the claude-code-native approach for portability)
  nativeBuildInputs = [ gnutar gzip ];
  buildInputs = [ ];

  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  unpackPhase = ''
    tar xzf $src
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp codex-${platformInfo.target} $out/bin/codex
    chmod +x $out/bin/codex
    runHook postInstall
  '';

  meta = {
    description = "Codex - OpenAI's coding agent that runs locally on your computer";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    platforms = lib.attrNames platforms;
    mainProgram = "codex";
  };
}
