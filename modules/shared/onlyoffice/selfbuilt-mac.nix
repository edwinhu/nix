# ONLYOFFICE Document Builder 9.4.0 for aarch64-darwin — SELF-BUILT from AGPL
# source (ONLYOFFICE/build_tools, mac_arm64), therefore WATERMARK-FREE:
# unlike the official binary tarball, docbuilder output (PDF/PNG render and
# xlsx recalc via Api.RecalculateAllFormulas) carries no "Unregistered
# Version" watermark. Verified 2026-06-10; build recipe + investigation:
# ~/projects/workflows/docs/investigations/2026-06-10_onlyoffice-vs-libreoffice.md
#
# The tarball is a local artifact (not fetchable from the internet). It lives
# at ~/.local/share/onlyoffice-selfbuilt/ and is hash-pinned here via
# requireFile — if missing from the store, nix prints instructions to re-add
# it (nix store prefetch-file file://...tar.xz), or rebuild from source per
# the investigation doc (~25 min compile on M-series).
#
# Linux gets the equivalent via docbuilder.nix (hermetic nixpkgs source build).
{ lib, stdenv, requireFile, makeWrapper }:

stdenv.mkDerivation {
  pname = "onlyoffice-docbuilder-selfbuilt";
  version = "9.4.0";

  src = requireFile {
    name = "onlyoffice-documentbuilder-9.4.0-selfbuilt-mac_arm64.tar.xz";
    sha256 = "sha256-taZW0ZORZj7y5KMdmIgIbaX/uXwqkju0ZxlnPfqoVRU=";
    message = ''
      The self-built ONLYOFFICE Document Builder tarball is missing from the
      nix store. Re-add it with:
        nix store prefetch-file \
          file://$HOME/.local/share/onlyoffice-selfbuilt/onlyoffice-documentbuilder-9.4.0-selfbuilt-mac_arm64.tar.xz
      or rebuild from source (recipe in
      ~/projects/workflows/docs/investigations/2026-06-10_onlyoffice-vs-libreoffice.md).
    '';
  };

  sourceRoot = "9.4.0-mac_arm64";

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Both binaries locate frameworks/sdkjs/DoctRenderer.config relative to
    # themselves — install the tree intact, wrap from outside.
    mkdir -p "$out/lib/onlyoffice-documentbuilder" "$out/bin"
    cp -R . "$out/lib/onlyoffice-documentbuilder/"

    makeWrapper "$out/lib/onlyoffice-documentbuilder/x2t" "$out/bin/x2t"
    makeWrapper "$out/lib/onlyoffice-documentbuilder/docbuilder" "$out/bin/docbuilder"

    runHook postInstall
  '';

  meta = {
    description = "ONLYOFFICE Document Builder + x2t, self-built from AGPL source (watermark-free)";
    homepage = "https://github.com/ONLYOFFICE/DocumentBuilder";
    license = lib.licenses.agpl3Only;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "docbuilder";
  };
}
