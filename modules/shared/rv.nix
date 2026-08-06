# rv - R package manager (gh:a2-ai/rv)
# Prebuilt release binary; not in nixpkgs (`nix search nixpkgs '^rv$'` only
# finds haskellPackages.rv, an unrelated RISC-V library).
#
# Linux uses the musl assets: they're static-pie, so no interpreter and no
# autoPatchelf/dontFixup FHS assumption — works on Omarchy/Arch and NixOS alike.
# Previously installed by a home-manager activation script that curl-piped
# https://a2-ai.github.io/rv-docs/install.sh into bash; upstream deleted that
# URL and the pipeline swallowed curl's 404 (bash exits 0 on empty stdin), so
# rv silently vanished from new machines. Hence: a real derivation.
{ lib, stdenv, fetchurl }:

let
  version = "0.22.2";

  platforms = {
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-aq2MEbWejuQo/877WAyPKxp5lnZKwGyrLrkzobEpGbU=";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-musl";
      hash = "sha256-hOuL4SBkBqiZ6Ctx8LOTQsAGOr0bM2LBuppmLs7XQi8=";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hash = "sha256-lVYlqfb2BrKb74KWpRbvfoMj1knbqlIOfQ5yI5t4JqA=";
    };
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-Ym4yBaEju7J1AXeZ5joVSNzXuPQvN9CbjfV/mVbs+VY=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (lib.attrNames platforms)}.");

in stdenv.mkDerivation {
  pname = "rv";
  inherit version;

  src = fetchurl {
    url = "https://github.com/a2-ai/rv/releases/download/v${version}/rv-v${version}-${platformInfo.target}.tar.gz";
    inherit (platformInfo) hash;
  };

  # Tarball is a single bare `rv` binary, no top-level directory.
  sourceRoot = ".";

  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 rv $out/bin/rv
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/rv --version
  '';

  meta = {
    description = "R package manager with project-local libraries and a declarative manifest";
    homepage = "https://github.com/a2-ai/rv";
    license = lib.licenses.mit;
    mainProgram = "rv";
    platforms = lib.attrNames platforms;
  };
}
