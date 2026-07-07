# OmniWM — tiling window manager for macOS, fetched straight from GitHub
# releases. The barutsrb Homebrew tap lags upstream by weeks (was pinned at
# 0.4.8.1 while upstream shipped 0.5.x), so we self-manage the version here:
# bump `version` + `hash`, then `nix run .#build-switch`.
#
# OmniWM is ad-hoc signed (no Developer ID), so macOS re-prompts for
# Accessibility on every version bump regardless of install method — same
# behaviour as Karabiner/Hammerspoon. The .app is landed at a stable
# /Applications/OmniWM.app path via modules/darwin/defaults.nix postActivation
# (not the churning /Applications/Nix Apps symlink), so Finder/Spotlight stay
# sane and grants persist if OmniWM ever ships proper signing.
{ lib, stdenv, fetchzip }:

stdenv.mkDerivation (finalAttrs: {
  pname = "omniwm";
  version = "0.5.4";

  # The release zip contains OmniWM.app/ at top level; keep it (don't strip).
  src = fetchzip {
    url = "https://github.com/BarutSRB/OmniWM/releases/download/v${finalAttrs.version}/OmniWM-v${finalAttrs.version}.zip";
    hash = "sha256-I3LxVkH3BoqvJX5qXguv22r1pznCgdk+W8hOuROGdTQ=";
    stripRoot = false;
  };

  dontBuild = true;
  # Preserve the ad-hoc Mach-O signature: no stripping/re-signing.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -R OmniWM.app "$out/Applications/OmniWM.app"
    runHook postInstall
  '';

  meta = {
    description = "OmniWM tiling window manager for macOS";
    homepage = "https://github.com/BarutSRB/OmniWM";
    platforms = lib.platforms.darwin;
  };
})
