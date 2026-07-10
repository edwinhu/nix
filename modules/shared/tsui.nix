# tsui - terminal UI for Tailscale (gh:neuralink/tsui)
# Prebuilt release binary. Not in nixpkgs; both linux arches ship an asset.
# Ordinary dynamically-linked ELF — on FHS hosts (Omarchy/Arch) it runs against
# system libs unpatched, so dontFixup is fine (would need autoPatchelf on NixOS).
{ lib, stdenv, fetchurl }:

let
  version = "0.2.0";

  platforms = {
    x86_64-linux = {
      asset = "tsui-linux-x86_64";
      hash = "sha256-zPzBQIrWleZxzBJyrplp2ZYKSIkPrxIBXBE0zGQf1mc=";
    };
    aarch64-linux = {
      asset = "tsui-linux-aarch64";
      hash = "sha256-IYpHfFr89NY7BnDeJ6OUv0x4oWyoOCiaG9zfybUGqYI=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Supported: x86_64-linux, aarch64-linux.");

in stdenv.mkDerivation {
  pname = "tsui";
  inherit version;

  src = fetchurl {
    url = "https://github.com/neuralink/tsui/releases/download/v${version}/${platformInfo.asset}";
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
    cp $src $out/bin/tsui
    chmod +x $out/bin/tsui
    runHook postInstall
  '';

  meta = {
    description = "Terminal UI for Tailscale";
    homepage = "https://github.com/neuralink/tsui";
    license = lib.licenses.mit;
    mainProgram = "tsui";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
