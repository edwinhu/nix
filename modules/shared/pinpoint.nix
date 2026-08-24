# pinpoint — Edwin's unofficial CLI for Google Pinpoint (gh:edwinhu/pinpoint,
# PRIVATE). Prebuilt Go binary from the GitHub release, same shape as
# paperpile-cli.nix and hylo.nix.
#
# Statically linked (CGO_ENABLED=0), so no autoPatchelf and no glibc coupling —
# dontFixup is safe on FHS hosts and NixOS alike, unlike the dynamically-linked
# Bun binaries next door.
#
# The repo is PRIVATE, so the plain releases/download URL 404s for an
# unauthenticated fetcher. Like hylo.nix and paperpile-cli.nix we hit the REST
# asset endpoint with `Accept: application/octet-stream`; the Nix daemon
# authenticates via the api.github.com entry in its netrc. The custom Accept
# header forces fetchurl onto its shell-curl builder (which runs in the FOD
# sandbox), so the netrc must be reachable there AND passed to curl explicitly.
#
# Host setup is shared with hylo/paperpile-cli and already configured:
#   1. /etc/nix/github-netrc (mode 644):
#        machine api.github.com login <PAT> password x-oauth-basic
#   2. /etc/nix/nix.custom.conf:  extra-sandbox-paths = /etc/nix/github-netrc
#
# WHY A PREBUILT ASSET RATHER THAN buildGoModule: a source build needs the
# sandbox to clone a private repo, which the netrc above does not cover
# (it authenticates api.github.com, not the git transport). Shipping the
# compiled artifact keeps one auth mechanism instead of two.
#
# Update flow: bump `version`, cross-compile both targets
#   CGO_ENABLED=0 GOOS=linux  GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o pinpoint-linux-x64    ./cmd/pinpoint
#   CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o pinpoint-darwin-arm64 ./cmd/pinpoint
# then `gh release create v<version> <both files>`, grab the per-platform asset id
#   gh api repos/edwinhu/pinpoint/releases/tags/v<version> --jq '.assets[] | "\(.id) \(.name)"'
# and update `assetId` + `hash`
#   nix hash convert --hash-algo sha256 --to sri $(sha256sum <asset> | cut -d' ' -f1)
{ lib, stdenv, fetchurl }:

let
  version = "0.1.0";

  # Per-platform release asset ids + hashes (all attached to the v${version}
  # release, built from 69fcbc8).
  platforms = {
    x86_64-linux = {
      assetId = "526931018"; # pinpoint-linux-x64
      hash = "sha256-paDj0bBsh7NswN6dGmAsD61cGPlv4oWwxrXtmHawGk0=";
    };
    aarch64-darwin = {
      assetId = "526931017"; # pinpoint-darwin-arm64
      hash = "sha256-33CodnTETvGyfb3hVLgc/i+ntj217lfLfyUolVf3oKs=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or
    (throw "pinpoint: unsupported platform ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (builtins.attrNames platforms)}. Cross-compile for that platform, upload to the v${version} release, and add its assetId+hash here.");

in stdenv.mkDerivation {
  pname = "pinpoint";
  inherit version;

  src = fetchurl {
    name = "pinpoint-${version}-${stdenv.hostPlatform.system}";
    url = "https://api.github.com/repos/edwinhu/pinpoint/releases/assets/${platformInfo.assetId}";
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
    cp $src $out/bin/pinpoint
    chmod +x $out/bin/pinpoint
    runHook postInstall
  '';

  meta = {
    description = "Unofficial CLI for Google Pinpoint (collections, upload, search, structured extraction)";
    homepage = "https://github.com/edwinhu/pinpoint";
    license = lib.licenses.unfree; # private repo
    mainProgram = "pinpoint";
    platforms = builtins.attrNames platforms;
  };
}
