# Chrome for Testing — headless-capable Chrome that doesn't conflict with GUI Chrome
# Used by nanoclaw and readwise headless services instead of the main Google Chrome binary.
# Download URLs: https://googlechromelabs.github.io/chrome-for-testing/
{ lib, stdenv, fetchurl, unzip }:

let
  version = "146.0.7680.72";

  platforms = {
    aarch64-darwin = {
      arch = "mac-arm64";
      hash = "sha256-SXrHThHgWGgOEWdo3UIQwJoNlN+bAAR4ZK+qO/upUlQ=";
    };
    x86_64-darwin = {
      arch = "mac-x64";
      hash = ""; # TODO: prefetch if needed
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system}
    or (throw "chrome-for-testing: unsupported platform ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "chrome-for-testing";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/chrome-for-testing-public/${version}/${platformInfo.arch}/chrome-${platformInfo.arch}.zip";
    inherit (platformInfo) hash;
  };

  nativeBuildInputs = [ unzip ];

  sourceRoot = "chrome-${platformInfo.arch}";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"
    cp -r "Google Chrome for Testing.app" "$out/Applications/"

    # Wrapper script so headless services can use $out/bin/chrome-for-testing
    cat > "$out/bin/chrome-for-testing" <<WRAPPER
    #!/bin/bash
    exec "$out/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" "\$@"
    WRAPPER
    chmod +x "$out/bin/chrome-for-testing"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Google Chrome for Testing — automation-friendly Chrome without auto-update";
    homepage = "https://googlechromelabs.github.io/chrome-for-testing/";
    license = licenses.unfree;
    platforms = [ "aarch64-darwin" "x86_64-darwin" ];
  };
}
