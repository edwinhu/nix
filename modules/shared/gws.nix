# Google Workspace CLI
# Pre-built binaries from https://github.com/googleworkspace/cli
{ lib, stdenv, fetchurl, autoPatchelfHook }:

let
  version = "0.22.5";

  platforms = {
    x86_64-linux = {
      platform = "x86_64-unknown-linux-gnu";
      hash = "sha256-3njs29LxqEzKAGOn7LxEAkD8FLbrzLsX9GRreSqMXB8=";
    };
    aarch64-linux = {
      platform = "aarch64-unknown-linux-gnu";
      hash = "sha256-lEkCldlYDh6IV05xWgoWKZF0fRLWL4x7jcyCaLbBzqA=";
    };
    x86_64-darwin = {
      platform = "x86_64-apple-darwin";
      hash = "sha256-Ufm9cxQE1LuibDbi4w3WjFbczR+DTAElLLCxTWplRLI=";
    };
    aarch64-darwin = {
      platform = "aarch64-apple-darwin";
      hash = "sha256-HSqf/VvJssLEtIYw2vCC+tE9nlfXQZiKLCSO7VYvfaw=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "gws";
  inherit version;

  src = fetchurl {
    url = "https://github.com/googleworkspace/cli/releases/download/v${version}/google-workspace-cli-${platformInfo.platform}.tar.gz";
    inherit (platformInfo) hash;
  };

  sourceRoot = ".";

  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp gws $out/bin/.gws-unwrapped
    chmod +x $out/bin/.gws-unwrapped
    cat > $out/bin/gws <<EOF
#!/bin/sh
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="\''${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-file}"
exec "$out/bin/.gws-unwrapped" "\$@"
EOF
    chmod +x $out/bin/gws
    runHook postInstall
  '';

  meta = {
    description = "Google Workspace CLI - command-line interface for Google Workspace APIs";
    homepage = "https://github.com/googleworkspace/cli";
    license = lib.licenses.asl20;
    platforms = lib.attrNames platforms;
    mainProgram = "gws";
  };
}
