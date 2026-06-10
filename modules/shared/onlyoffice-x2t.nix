# ONLYOFFICE x2t converter, extracted from the official Document Builder tarball.
# Replaces LibreOffice for docx/pptx/xlsx -> PDF/PNG conversion (OOXML-native
# engine: renders Word semantics correctly where soffice doesn't, e.g. footnote
# numRestart; stateless, parallel-safe, ~150 MB vs ~1 GB).
#
# bin/x2t       — watermark-free converter. Direct: `x2t in.docx out.pdf` needs a
#                 writable CWD for temp files; for control use an XML params file
#                 (m_sFileFrom/m_sFileTo/m_sTempDir/m_sFontDir).
# bin/docbuilder — JS-scripted generation/edit engine. NOTE: the free binary
#                 watermarks all output ("Unregistered Version"); kept only for
#                 experimentation. Do not use for real documents.
#
# Investigation: ~/projects/workflows/docs/investigations/2026-06-10_onlyoffice-vs-libreoffice.md
{ lib, stdenv, fetchurl, autoPatchelfHook ? null, makeWrapper }:

let
  version = "9.4.0";

  platforms = {
    aarch64-darwin = {
      arch = "macos-arm64";
      hash = "sha256-yZ7hiHJvlFDkHKXxmPPBQOvUNyfYxnjbcByMbjMgIWs=";
    };
    x86_64-linux = {
      arch = "linux-x86_64";
      hash = "sha256-FcAokv6hWLdq00P01YB2PDDL0VGpjwWVR417b4WZQ3o=";
    };
    aarch64-linux = {
      arch = "linux-aarch64";
      hash = "sha256-h1awtXpKtLJ2CKax++sT9nZwveAkXaFmkHJ3ghr7644=";
    };
  };

  platformInfo = platforms.${stdenv.hostPlatform.system}
    or (throw "onlyoffice-x2t: unsupported platform ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "onlyoffice-x2t";
  inherit version;

  src = fetchurl {
    url = "https://github.com/ONLYOFFICE/DocumentBuilder/releases/download/v${version}/onlyoffice-documentbuilder-${platformInfo.arch}.tar.xz";
    inherit (platformInfo) hash;
  };

  # Tarball has no top-level directory
  sourceRoot = ".";

  nativeBuildInputs = [ makeWrapper ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  # Linux binaries ship their own bundled .so deps; don't fail on optional ones
  autoPatchelfIgnoreMissingDeps = stdenv.hostPlatform.isLinux;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # x2t locates its frameworks/sdkjs/DoctRenderer.config relative to the
    # binary, so install the whole tree intact and wrap from outside.
    mkdir -p "$out/lib/onlyoffice-documentbuilder" "$out/bin"
    cp -R . "$out/lib/onlyoffice-documentbuilder/"
    rm -f "$out/lib/onlyoffice-documentbuilder/env-vars"

    makeWrapper "$out/lib/onlyoffice-documentbuilder/x2t" "$out/bin/x2t"
    makeWrapper "$out/lib/onlyoffice-documentbuilder/docbuilder" "$out/bin/docbuilder"

    runHook postInstall
  '';

  passthru = {
    # Bundled basic fonts; pass as m_sFontDir, or point at a richer font dir
    # (Times New Roman etc.) for fidelity with real documents.
    fontsDir = "lib/onlyoffice-documentbuilder/fonts";
  };

  meta = {
    description = "ONLYOFFICE x2t document converter (docx/pptx/xlsx to PDF/PNG, OOXML-native)";
    homepage = "https://github.com/ONLYOFFICE/DocumentBuilder";
    license = lib.licenses.agpl3Only;
    platforms = builtins.attrNames platforms;
    mainProgram = "x2t";
  };
}
