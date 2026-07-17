# OpenWhispr — open-source local dictation + AI meeting notes (Electron),
# fetched as the upstream release AppImage. This is the Linux stand-in for
# granola, which is macOS-only (see modules/darwin/casks.nix).
#
# appimageTools.wrapType2 extracts the AppImage into an FHS runtime at build
# time, so the host needs neither libfuse nor a system Electron. The nixGLIntel
# wrap + --no-sandbox (Chromium can't use the non-setuid store chrome-sandbox)
# is applied one level up, in the flake overlay, exactly like hylo/beeper.
#
# Only the icon is installed here; the .desktop is declared in the omarchy host
# (xdg.desktopEntries.openwhispr) so its Exec points at the nixGL-wrapped
# `openwhispr` on PATH rather than the AppImage's bundled `Exec=AppRun`.
#
# Update flow: bump `version`, then take the new hash from
#   gh release view --repo OpenWhispr/openwhispr --json assets \
#     --jq '.assets[] | select(.name | endswith("x86_64.AppImage")) | .digest'
# and convert it: `nix hash convert --hash-algo sha256 --to sri <sha256>`.
{ lib, fetchurl, appimageTools, pulseaudio, procps }:

let
  pname = "openwhispr";
  version = "1.7.5";

  src = fetchurl {
    name = "openwhispr-${version}.AppImage";
    url = "https://github.com/OpenWhispr/openwhispr/releases/download/v${version}/OpenWhispr-${version}-linux-x86_64.AppImage";
    hash = "sha256-InmwYfIw+CfvCYx2DwZDIS9l/yj+MK5m7AUoT0TvbO4=";
  };

  # Recover the 256px icon electron-builder baked into the AppImage. Installed
  # under the `openwhispr` name (upstream calls it `open-whispr`) so it matches
  # the Icon= key of the home-manager desktop entry.
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  # The meeting-notes feature (the reason this stands in for granola) shells out
  # to `pactl subscribe` to notice a call's audio streams and to `ps` to identify
  # the conferencing app. Neither is in the AppImage's FHS runtime, so without
  # these the app still dictates but silently logs `spawn pactl ENOENT` /
  # `spawn ps ENOENT` and never auto-detects a meeting.
  extraPkgs = pkgs: [ pulseaudio procps ];

  extraInstallCommands = ''
    install -Dm444 ${contents}/usr/share/icons/hicolor/256x256/apps/open-whispr.png \
      $out/share/icons/hicolor/256x256/apps/openwhispr.png
  '';

  meta = {
    description = "Local-first dictation and AI meeting notes (whisper.cpp)";
    homepage = "https://openwhispr.com";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "openwhispr";
  };
}
