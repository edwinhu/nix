# morgen-cli - CLI and MCP server for Morgen calendar
# Pre-built binary from GitHub releases
{ lib, stdenv, fetchurl }:

let
  version = "0.10.0";

  # Prebuilt Bun binaries per platform. The linux-x64 asset is a normal
  # dynamically-linked ELF; on FHS hosts (Omarchy/Arch) it runs against system
  # glibc unpatched, so dontFixup is fine (would need autoPatchelf on NixOS).
  platforms = {
    aarch64-darwin = {
      asset = "morgen-darwin-arm64";
      hash = "sha256-apoBoKRyG6Cm4/s7HR5Tr7eghWTq/rCVB0WR1v38Qps=";
    };
    x86_64-linux = {
      asset = "morgen-linux-x64";
      hash = "sha256-RdshwAdrVVM9PGNj64btdn3ukE7WgHptg/4oxqX6brg=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Supported: aarch64-darwin, x86_64-linux.");

in stdenv.mkDerivation {
  pname = "morgen-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/edwinhu/morgen-cli/releases/download/v${version}/${platformInfo.asset}";
    inherit (platformInfo) hash;
  };

  dontUnpack = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/morgen
    chmod +x $out/bin/morgen
    runHook postInstall
  '';

  meta = {
    description = "CLI and MCP server for Morgen calendar";
    homepage = "https://github.com/edwinhu/morgen-cli";
    license = lib.licenses.mit;
    mainProgram = "morgen";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
  };
}
