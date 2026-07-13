# superhuman-cli - CLI and MCP server for Superhuman email
# Pre-built binary from GitHub releases
{ lib, stdenv, fetchurl }:

let
  version = "0.38.2";

  # Prebuilt Bun binaries per platform. The linux-x64 asset is a normal
  # dynamically-linked ELF; on FHS hosts (Omarchy/Arch) it runs against system
  # glibc unpatched, so dontFixup is fine (would need autoPatchelf on NixOS).
  platforms = {
    aarch64-darwin = {
      # The release CI (.github/workflows/release.yml) publishes the darwin
      # binary as superhuman-darwin-arm64. (v0.38.0 also had a bare `superhuman`
      # asset added out-of-band; new tag-triggered releases do not, so track the
      # CI name.)
      asset = "superhuman-darwin-arm64";
      hash = "sha256-nZwdzIeXOi5sBdSjIc7Nv71678jjHQzxos3e6QBgMWU=";
    };
    x86_64-linux = {
      asset = "superhuman-linux-x64";
      hash = "sha256-d993LuHdPtBlB/uu1BoGIEWAqy/YeOc9Oxe0fPzgJ10=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}. Supported: aarch64-darwin, x86_64-linux.");

in stdenv.mkDerivation {
  pname = "superhuman-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/edwinhu/superhuman-cli/releases/download/v${version}/${platformInfo.asset}";
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
    cp $src $out/bin/superhuman
    chmod +x $out/bin/superhuman
    runHook postInstall
  '';

  meta = {
    description = "CLI and MCP server for Superhuman email";
    homepage = "https://github.com/edwinhu/superhuman-cli";
    license = lib.licenses.mit;
    mainProgram = "superhuman";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
  };
}
