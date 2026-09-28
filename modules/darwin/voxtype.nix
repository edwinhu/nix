# voxtype — push-to-talk dictation + meeting transcription, from the upstream
# universal macOS release binary. The peteonrails/voxtype Homebrew tap lags
# releases by months (cask 0.7.5, formula 0.6.3 while upstream shipped 1.1.0),
# so the version is pinned here: bump `version` + `hash`, then build-switch.
# The binary is unsigned; macOS Input Monitoring / Microphone grants go to the
# terminal (or launchd job) that runs `voxtype daemon`.
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "voxtype";
  version = "1.1.0";

  src = fetchurl {
    url = "https://github.com/peteonrails/voxtype/releases/download/v${finalAttrs.version}/voxtype-${finalAttrs.version}-macos-universal";
    hash = "sha256-EsNPjXSfTD7MxW5jub/Hy5LhCpsgiUAmAxYYh/yq7yU=";
  };

  dontUnpack = true;
  # Keep the upstream Mach-O untouched (no strip / re-sign).
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/voxtype"
    runHook postInstall
  '';

  meta = {
    description = "Push-to-talk voice-to-text and meeting transcription";
    homepage = "https://voxtype.io";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "voxtype";
  };
})
