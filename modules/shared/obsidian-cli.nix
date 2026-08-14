# obsidian-cli — Edwin's Bun/TypeScript CLI for the Obsidian vault
# (gh:edwinhu/obsidian-cli, PRIVATE). Prebuilt Bun binary from the GitHub
# release, installed like paperpile-cli/superhuman-cli.
#
# What it is: `obsidian clip` is a web clipper (Defuddle + Turndown, the same
# engine as the official Web Clipper extension) that writes markdown straight
# into the vault on disk — it needs no running Obsidian app. Every OTHER
# subcommand is proxied to the native Obsidian binary, which is why this
# package installs itself as `obsidian` and the GUI moves to `obsidian-app`
# (see the overlay in flake.nix — a bare `obsidian` target would make the
# proxy exec itself, so OBSIDIAN_BINARY is pinned to an absolute store path).
#
# The linux-x64 asset is an ordinary dynamically-linked ELF; on FHS hosts
# (Omarchy/Arch) it runs against system glibc unpatched, so dontFixup is fine
# (would need autoPatchelf on NixOS).
#
# The repo is PRIVATE, so the plain releases/download URL 404s for an
# unauthenticated fetcher. Like hylo.nix/paperpile-cli.nix, we hit the REST
# asset endpoint with `Accept: application/octet-stream`; the Nix daemon
# authenticates via the api.github.com entry in its netrc. The custom Accept
# header forces fetchurl onto its shell-curl builder (which runs in the FOD
# sandbox), so the netrc must be reachable there AND passed to curl
# explicitly. See paperpile-cli.nix for the one-time host setup
# (/etc/nix/github-netrc + extra-sandbox-paths).
#
# Update flow: bump `version`, build both binaries from ~/projects/obsidian-cli
# (`bun build src/cli.ts --compile --outfile obsidian-linux-x64` and
# `--target=bun-darwin-arm64 --outfile obsidian-darwin-arm64` — Bun
# cross-compiles, so one machine can produce both), `gh release create
# v<version> ...`, grab the per-platform asset id
# (`gh api repos/edwinhu/obsidian-cli/releases/tags/v<version> --jq
# '.assets[] | "\(.id) \(.name)"'`), update `assetId` + `hash`
# (`nix hash convert --hash-algo sha256 --to sri $(sha256sum <asset>|cut -d' ' -f1)`).
{ lib, stdenv, fetchurl }:

let
  version = "0.1.1";

  # Per-platform release asset ids + hashes (all attached to the v${version}
  # release).
  platforms = {
    x86_64-linux = {
      assetId = "514739306"; # obsidian-linux-x64
      hash = "sha256-lbmC/HTcbgSjhdvuk4RJcbkIRPHlIXJwM+7hSgWNpy4=";
    };
    aarch64-linux = {
      assetId = "514739307"; # obsidian-linux-arm64
      hash = "sha256-HABcZT9CHQ2k3Ioxvm66KSg3NKigr8es74uChhgIKMU=";
    };
    aarch64-darwin = {
      assetId = "514739308"; # obsidian-darwin-arm64
      hash = "sha256-FBDgijmWC0ESlNy1fZxDwqXqWNojPiwC6EmS8pVp/Tc=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system} or
    (throw "obsidian-cli: unsupported platform ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (builtins.attrNames platforms)}. Build the binary for that platform, upload to the v${version} release, and add its assetId+hash here.");

in stdenv.mkDerivation {
  pname = "obsidian-cli";
  inherit version;

  src = fetchurl {
    name = "obsidian-cli-${version}-${stdenv.hostPlatform.system}";
    url = "https://api.github.com/repos/edwinhu/obsidian-cli/releases/assets/${platformInfo.assetId}";
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

  # Installed as `obsidian-cli`. The Linux overlay re-wraps it under the same
  # name with OBSIDIAN_BINARY pointed at the GUI, so passthrough works there.
  #
  # NAME COLLISION (Linux): nixpkgs' `obsidian` package also ships a
  # `bin/obsidian-cli` (Obsidian's official CLI). The flake overlay resolves
  # this inside the obsidian symlinkJoin — ours is listed first and wins, the
  # official one stays reachable via `obsidian.unwrapped`. So do NOT also add
  # this package to modules/linux/omarchy-packages.nix: two profile entries
  # claiming `bin/obsidian-cli` is a real conflict, not a first-wins merge.
  # Darwin ships the GUI as a cask with no such binary, so there it is
  # installed by name directly.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/obsidian-cli
    chmod +x $out/bin/obsidian-cli
    runHook postInstall
  '';

  meta = {
    description = "CLI for the Obsidian vault (web clipper + passthrough to the native app)";
    homepage = "https://github.com/edwinhu/obsidian-cli";
    license = lib.licenses.unfree; # private repo, no declared license
    mainProgram = "obsidian-cli";
    platforms = builtins.attrNames platforms;
  };
}
