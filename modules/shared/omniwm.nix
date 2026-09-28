# OmniWM — tiling window manager for macOS, fetched straight from GitHub
# releases so the version is ours to pick: bump the release below + `hash`,
# then `nix run .#build-switch`.
#
# OmniWM is ad-hoc signed (no Developer ID), so macOS re-prompts for
# Accessibility on every version bump regardless of install method — same
# behaviour as Karabiner/Hammerspoon. The .app is landed at a stable
# /Applications/OmniWM.app path via modules/darwin/defaults.nix postActivation
# (not the churning /Applications/Nix Apps symlink), so Finder/Spotlight stay
# sane and grants persist if OmniWM ever ships proper signing.
#
# `tahoe` selects the release: 0.6+ requires macOS 26. Set it per host
# (userInfo.macosTahoe in flake.nix) once that host is on Tahoe.
{ lib, stdenv, fetchzip, tahoe ? false }:

let
  releases = {
    # 0.7.x: settings.toml schema 1→2 migrates itself on first launch (backup
    # at settings.toml.pre-v2); IPC 14, so omniwmctl must come from the same
    # bundle.
    tahoe = {
      version = "0.7.3";
      hash = "sha256-8Bwqy0hQRVaBqItn7EARmt+2DK2d6GmbgqziVlkAkKk=";
    };
    # Newest release that RUNS on macOS 15 (Sequoia):
    #   - v0.5.3+ raised LSMinimumSystemVersion to macOS 26 (Tahoe).
    #   - v0.5.2.1 links SLSWindowIteratorGetCornerRadii, absent on 15.7 → crash.
    # Known bug: tiles non-standard AX windows (AXUnknown menubar items,
    # AXDialog panels). Do NOT downgrade to 0.4.8.1: it lacks appRules
    # assignToWorkspace/layout and rewrites settings.toml in its old schema.
    sequoia = {
      version = "0.5.2";
      hash = "sha256-Xh6I18aJNBjWy4WdMFclTJFiIaI3/XV0J30/QJUYa+0=";
    };
  };
  release = if tahoe then releases.tahoe else releases.sequoia;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "omniwm";
  inherit (release) version;

  # The release zip contains OmniWM.app/ at top level; keep it (don't strip).
  src = fetchzip {
    url = "https://github.com/BarutSRB/OmniWM/releases/download/v${finalAttrs.version}/OmniWM-v${finalAttrs.version}.zip";
    inherit (release) hash;
    stripRoot = false;
  };

  dontBuild = true;
  # Preserve the ad-hoc Mach-O signature: no stripping/re-signing.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -R OmniWM.app "$out/Applications/OmniWM.app"
    # fetchzip's unzip materializes macOS AppleDouble sidecars (._foo) as real
    # files inside the bundle, which are extra sealed resources that invalidate
    # the Developer-ID signature ("sealed resource is missing or invalid").
    # Strip them so codesign/Gatekeeper accept the notarized app.
    find "$out/Applications/OmniWM.app" \( -name '._*' -o -name '.DS_Store' \) -delete
    runHook postInstall
  '';

  meta = {
    description = "OmniWM tiling window manager for macOS";
    homepage = "https://github.com/BarutSRB/OmniWM";
    platforms = lib.platforms.darwin;
  };
})
