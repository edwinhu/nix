{ lib, stdenv, fetchurl }:

let
  version = "1.2.1";

  platformTar = {
    "aarch64-darwin" = {
      suffix = "darwin_arm64";
      hash = "sha256-Iny07iISgZJIVEUgLc2AFEZ5/FdwPmCHBunBD3KulTk=";
    };
    "x86_64-darwin" = {
      suffix = "darwin_amd64";
      hash = "sha256-F0SmLP3jDnp/hvGgBKJ5v6CAWvHwl+l6ijvtNYJ3ku4=";
    };
    "x86_64-linux" = {
      suffix = "linux_amd64";
      hash = "sha256-6k+EIJO4tbd4Tz0cXQcL47rsLFjFBQHfVpwrMO1CxAw=";
    };
    "aarch64-linux" = {
      suffix = "linux_arm64";
      hash = "sha256-KrMC2+uqUL0nSVk630h96qKgCzLan5EqRV0pVCvPvTI=";
    };
  }.${stdenv.hostPlatform.system} or (throw "Unsupported platform for revdiff: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "revdiff";
  inherit version;

  src = fetchurl {
    url = "https://github.com/umputun/revdiff/releases/download/v${version}/revdiff_${version}_${platformTar.suffix}.tar.gz";
    hash = platformTar.hash;
  };

  sourceRoot = ".";

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 revdiff $out/bin/revdiff
    runHook postInstall
  '';

  meta = {
    description = "Review-first terminal diff viewer with inline annotations for AI agents";
    homepage = "https://github.com/umputun/revdiff";
    license = lib.licenses.mit;
    mainProgram = "revdiff";
    platforms = lib.platforms.unix;
  };
}
