# paperpile-cli — Edwin's Bun/TypeScript CLI for the Paperpile library
# (gh:edwinhu/paperpile-cli, PRIVATE). Prebuilt Bun binary from the GitHub
# release, installed like morgen-cli/superhuman-cli.
#
# The linux-x64 asset is an ordinary dynamically-linked ELF; on FHS hosts
# (Omarchy/Arch) it runs against system glibc unpatched, so dontFixup is fine
# (would need autoPatchelf on NixOS).
#
# The repo is PRIVATE, so the plain releases/download URL 404s for an
# unauthenticated fetcher. Like hylo.nix, we hit the REST asset endpoint with
# `Accept: application/octet-stream`; the Nix daemon authenticates via the
# api.github.com entry in its netrc. The custom Accept header forces fetchurl
# onto its shell-curl builder (which runs in the FOD sandbox), so the netrc
# must be reachable there AND passed to curl explicitly. Returned bytes are
# identical to the browser/gh download, so the hash is stable.
#
# One-time host setup (already configured for hylo; needs root, not managed
# here):
#   1. /etc/nix/github-netrc (mode 644):
#        machine api.github.com login <PAT> password x-oauth-basic
#   2. /etc/nix/nix.custom.conf:  extra-sandbox-paths = /etc/nix/github-netrc
#
# Update flow: bump `version`, build the binary (`bun build src/main.ts
# --compile --outfile paperpile-<os>-<arch>`), `gh release create v<version>
# ...`, grab the per-platform asset id
# (`gh api repos/edwinhu/paperpile-cli/releases/tags/v<version> --jq
# '.assets[] | "\(.id) \(.name)"'`), update `assetId` + `hash`
# (`nix hash convert --hash-algo sha256 --to sri $(sha256sum <asset>|cut -d' ' -f1)`).
{ lib, stdenv, fetchurl }:

let
  version = "0.6.2";

  # Per-platform release asset ids + hashes (all attached to the v${version}
  # release).
  platforms = {
    x86_64-linux = {
      assetId = "478754582"; # paperpile-linux-x64
      hash = "sha256-WFOStQhGNq7zDnCmE1VS2qWTr0qFlLy+AH1TFY4DCrQ=";
    };
    aarch64-darwin = {
      assetId = "478760849"; # paperpile-darwin-arm64
      hash = "sha256-I+i7SjEBmXtf57E9FFJwC4HccOJjJBM9eJDcZq9BBTA=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or
    (throw "paperpile-cli: unsupported platform ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (builtins.attrNames platforms)}. Build the binary on that platform, upload to the v${version} release, and add its assetId+hash here.");

in stdenv.mkDerivation {
  pname = "paperpile-cli";
  inherit version;

  src = fetchurl {
    name = "paperpile-${version}-${stdenv.hostPlatform.system}";
    url = "https://api.github.com/repos/edwinhu/paperpile-cli/releases/assets/${platformInfo.assetId}";
    curlOptsList = [
      "-H" "Accept: application/octet-stream"
      "--netrc-file" "/etc/nix/github-netrc"
    ];
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
    cp $src $out/bin/paperpile
    chmod +x $out/bin/paperpile
    runHook postInstall
  '';

  meta = {
    description = "CLI for the Paperpile library (pure HTTP; auth/search/add/attach/edit/find-and-add)";
    homepage = "https://github.com/edwinhu/paperpile-cli";
    license = lib.licenses.unfree; # private repo, no declared license
    mainProgram = "paperpile";
    platforms = builtins.attrNames platforms;
  };
}
