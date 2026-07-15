# hylo — Edwin's own Electron PDF reader (gh:edwinhu/hylo), fetched as the
# release AppImage and wrapped for a non-FUSE, non-NixOS host.
#
# appimageTools.wrapType2 extracts the AppImage into an FHS runtime at build
# time, so the target machine needs neither libfuse nor a system Electron. The
# nixGLIntel wrap + --no-sandbox (Chromium can't use the non-setuid store
# chrome-sandbox) is applied one level up, in the flake overlay, exactly like
# beeper/stremio/limux.
#
# Only the icon is installed here; the .desktop is declared in home-manager
# (xdg.desktopEntries.hylo) so its Exec can point at the wrapped `hylo` on PATH
# and pass a local path (%f), which the main process resolves from argv.
#
# edwinhu/hylo is PRIVATE, so the plain releases/download URL 404s for an
# unauthenticated fetcher. Instead we hit the REST asset endpoint with
# `Accept: application/octet-stream`; the Nix daemon authenticates via the
# api.github.com entry in its netrc. The custom Accept header forces
# pkgs.fetchurl onto its shell-curl builder (Nix's builtin:fetchurl can't set
# headers), which runs in the FOD sandbox — so the netrc must be reachable
# there AND passed to curl explicitly. The returned bytes are identical to the
# browser download, so the hash is stable.
#
# One-time host setup (needs root, not managed here). NB: do NOT reuse
# /nix/var/determinate/netrc — Determinate regenerates that file on every
# `nix-daemon` restart and drops any hand-added lines. Use a dedicated file:
#   1. /etc/nix/github-netrc (mode 644 so the in-sandbox build user can read the
#      bind mount) containing:
#        machine api.github.com login <PAT> password x-oauth-basic
#   2. /etc/nix/nix.custom.conf — add:
#        extra-sandbox-paths = /etc/nix/github-netrc
#      (so the shell-curl builder can read it inside the FOD sandbox), then
#      restart nix-daemon.
#
# Update flow: bump `version`, rebuild the AppImage (`bun run dist --linux` in
# the hylo checkout), `gh release upload`, grab the new asset id
# (`gh api repos/edwinhu/hylo/releases/tags/v<version> --jq '.assets[].id'`),
# update `assetId` + `hash` (from `nix hash file <appimage>`).
{ lib, fetchurl, appimageTools }:

let
  pname = "hylo";
  version = "0.1.1";
  assetId = "477379403";

  src = fetchurl {
    name = "hylo-${version}.AppImage";
    url = "https://api.github.com/repos/edwinhu/hylo/releases/assets/${assetId}";
    curlOptsList = [
      "-H" "Accept: application/octet-stream"
      "--netrc-file" "/etc/nix/github-netrc"
    ];
    hash = "sha256-etl4KQRbsaUfN3kTMd7mpNwyJpcQxo35GcPrUxNdl+I=";
  };

  # Recover the 512px icon electron-builder baked into the AppImage.
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -Dm444 ${contents}/usr/share/icons/hicolor/512x512/apps/hylo.png \
      $out/share/icons/hicolor/512x512/apps/hylo.png
  '';

  meta = {
    description = "Desktop PDF reader with persistent highlights and Readwise sync";
    homepage = "https://github.com/edwinhu/hylo";
    license = lib.licenses.unfree; # private repo, no declared license
    platforms = [ "x86_64-linux" ];
    mainProgram = "hylo";
  };
}
