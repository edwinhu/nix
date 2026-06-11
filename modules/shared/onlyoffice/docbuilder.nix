# ONLYOFFICE docbuilder + x2t, built from source via nixpkgs' hermetic x2t
# derivation (pkgs/by-name/on/onlyoffice-documentserver/x2t.nix), extended with
# the Document Builder binary (core/DesktopEditor/doctrenderer/app_builder).
#
# Why: the official prebuilt docbuilder watermarks all output ("Unregistered
# Version") — the watermark is productization in ONLYOFFICE's binaries only;
# the AGPL source has no watermark code (verified empirically 2026-06-10, see
# ~/projects/workflows/docs/investigations/2026-06-10_onlyoffice-vs-libreoffice.md).
# A source-built docbuilder gives watermark-free xlsx formula recalculation,
# which is the last thing LibreOffice was kept around for.
#
# The heavy components (kernel, graphics, doctrenderer, all format libs, sdkjs)
# come from Hydra's binary cache; only the x2t/docbuilder link step rebuilds.
# The nix-generated DoctRenderer.config in $out/bin already points at the
# store-path sdkjs + build-time-generated AllFonts.js, so unlike the official
# tarball no runtime font-index initialization is needed.
#
# linux uses nixpkgs' x2t.nix verbatim (Hydra cache hits); darwin uses our
# hermetic port of it (./hermetic/x2t.nix — same file + darwin conditionals:
# apple_silicon CONFIG, c++20 over the core_mac c++14 override, brotli for the
# bundled freetype, fixDarwinDylibNames, JavaScriptCore instead of v8).
{ pkgs, lib }:

let
  x2t =
    if pkgs.stdenv.isDarwin
    then pkgs.callPackage ./hermetic/x2t.nix { }
    else pkgs.callPackage "${pkgs.path}/pkgs/by-name/on/onlyoffice-documentserver/x2t.nix" { };
in
(x2t.overrideAttrs (prev: {
  pname = "onlyoffice-docbuilder";

  # Build the docbuilder app in the same env right after X2tConverter:
  # identical deps, icu flags, and BUILDRT layout.
  postBuild =
    (prev.postBuild or "")
    + ''
      pushd $BUILDRT/DesktopEditor/doctrenderer/app_builder
      # reuse the derivation's qmake flags, minus the x2t project file
      builderFlags=$(echo "$qmakeFlags" | sed 's/X2tConverter\.pro//')
      qmake $builderFlags docbuilder.pro
      make -j$NIX_BUILD_CORES
      popd
    '';

  # x2t's installPhase copies everything under $BUILDRT/build into $out/bin,
  # which now includes docbuilder — just verify it landed.
  postInstall =
    (prev.postInstall or "")
    + ''
      if [ ! -x $out/bin/docbuilder ]; then
        find $BUILDRT/build -type f -name 'docbuilder*' -exec cp {} $out/bin \; || true
      fi
      test -x $out/bin/docbuilder
      chmod +x $out/bin/docbuilder
    '';

  meta = (prev.meta or { }) // {
    description = "ONLYOFFICE Document Builder + x2t converter, source-built (watermark-free)";
    mainProgram = "docbuilder";
  };
})).overrideAttrs
  (prev: {
    passthru = (prev.passthru or { }) // {
      inherit x2t;
    };
  })
