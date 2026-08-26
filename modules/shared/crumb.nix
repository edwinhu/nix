# crumb — Edwin's browser-credential broker (gh:edwinhu/crumb, PRIVATE).
# One process owns the browser session cookies and hands them to any CLI in any
# language over stdout, the way ortie hands out OAuth tokens:
#   crumb state pinpoint                    verified page state as JSON
#   crumb cookies https://host/path         RFC 6265-scoped Cookie header
#   crumb sync --port 9250                  chrome-cdp profile -> the owned jar
#
# Prebuilt `bun build --compile` binary from the GitHub release. A source build
# is not an option: bun install needs network, which the Nix sandbox denies, and
# there is no fetchBunDeps the way there is fetchNpmDeps.
#
# dontStrip/dontPatchELF are load-bearing, exactly as in consensus.nix:
# `bun build --compile` APPENDS the bundled entrypoint to the bun runtime, so
# strip and patchelf discard it and leave a bare bun that prints its own help.
# That failure is silent — the binary still runs — so do not "tidy" these away.
# Unlike the statically-linked Go binaries next door (pinpoint.nix), this one is
# dynamically linked, hence dontFixup is NOT used here.
#
# The repo is PRIVATE, so the plain releases/download URL 404s for an
# unauthenticated fetcher. Like hylo.nix and pinpoint.nix we hit the REST asset
# endpoint with `Accept: application/octet-stream`; the Nix daemon authenticates
# via the api.github.com entry in its netrc. The custom Accept header forces
# fetchurl onto its shell-curl builder (which runs in the FOD sandbox), so the
# netrc must be reachable there AND passed to curl explicitly.
#
# Host setup is shared with hylo/pinpoint and already configured:
#   1. /etc/nix/github-netrc (mode 644):
#        machine api.github.com login <PAT> password x-oauth-basic
#   2. /etc/nix/nix.custom.conf:  extra-sandbox-paths = /etc/nix/github-netrc
#
# Update flow: bump `version`, cross-compile both targets from one machine
#   bun build --compile --target=bun-linux-x64    src/index.ts --outfile crumb-linux-x64
#   bun build --compile --target=bun-darwin-arm64 src/index.ts --outfile crumb-darwin-arm64
# then `gh release create v<version> <both files>`, grab the per-platform asset id
#   gh api repos/edwinhu/crumb/releases/tags/v<version> --jq '.assets[] | "\(.id) \(.name)"'
# and update `assetId` + `hash`
#   nix hash convert --hash-algo sha256 --to sri $(sha256sum <asset> | cut -d' ' -f1)
{ lib, stdenv, fetchurl }:

let
  version = "0.2.0";

  # Per-platform release asset ids + hashes, all attached to the v${version}
  # release and built from 8ae704b.
  platforms = {
    x86_64-linux = {
      assetId = "530927198"; # crumb-linux-x64
      hash = "sha256-VPoHgMrvwH/kpXSEstB/g+fwjyNgabXc2lI2DtNAZsg=";
    };
    aarch64-darwin = {
      assetId = "530927201"; # crumb-darwin-arm64
      hash = "sha256-6ZctLwaSfe0mYOzmQVBFI78B9Ms8EZdZY9/zbUMDKBY=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or
    (throw "crumb: unsupported platform ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (builtins.attrNames platforms)}. Cross-compile for that platform, upload to the v${version} release, and add its assetId+hash here.");

in stdenv.mkDerivation {
  pname = "crumb";
  inherit version;

  src = fetchurl {
    name = "crumb-${version}-${stdenv.hostPlatform.system}";
    url = "https://api.github.com/repos/edwinhu/crumb/releases/assets/${platformInfo.assetId}";
    curlOptsList = [
      "-H" "Accept: application/octet-stream"
      "--netrc-file" "/etc/nix/github-netrc"
    ];
    inherit (platformInfo) hash;
  };

  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/crumb
    chmod +x $out/bin/crumb
    runHook postInstall
  '';

  meta = {
    description = "Browser-credential broker: verified page state and scoped cookies over stdout";
    homepage = "https://github.com/edwinhu/crumb";
    license = lib.licenses.unfree; # private repo, no declared license
    mainProgram = "crumb";
    platforms = builtins.attrNames platforms;
  };
}
