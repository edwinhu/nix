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
  # Pinned to the newest release that actually RUNS on macOS 15 (Sequoia):
  #   - v0.5.3+ raised LSMinimumSystemVersion to macOS 26 (Tahoe): won't launch.
  #   - v0.5.2.1 claims min-OS 15.0 but links a SkyLight symbol
  #     (SLSWindowIteratorGetCornerRadii) absent on 15.7 → fatal crash at launch.
  #   - v0.5.2 is the last build without that dependency.
  # Revisit this ceiling after upgrading macOS to 26 (Tahoe).
  #
  # Known 0.5.2 bug (2026-07-08, report upstream / re-check on next bump):
  # tiles non-standard AX windows (AXUnknown menubar status items, AXDialog
  # panels) — e.g. cmux's "Item-0" menubar icon gets a tiling slot, breaking
  # single-window centering. Do NOT chase it by downgrading: 0.4.8.1 lacks
  # appRules assignToWorkspace/layout entirely and re-serializes settings.toml
  # in its old schema on launch (drops those keys + resets hotkeys).
  version = "0.5.2";

  # The release zip contains OmniWM.app/ at top level; keep it (don't strip).
  src = fetchzip {
    url = "https://github.com/BarutSRB/OmniWM/releases/download/v${finalAttrs.version}/OmniWM-v${finalAttrs.version}.zip";
    hash = "sha256-Xh6I18aJNBjWy4WdMFclTJFiIaI3/XV0J30/QJUYa+0=";
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
