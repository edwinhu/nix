# swlinux — local Wayland/Hyprland dictation (Parakeet STT + local-LLM cleanup).
# Source fetched from github (gh:edwinhu/superwhisper-linux) via the swlinux-src
# flake input. STT/LLM deps come prebuilt from nixpkgs (sherpa-onnx, llama-cpp);
# the GTK layer-shell HUD runs under a small pygobject3 python and inherits the
# GI_TYPELIB_PATH that wrapGAppsHook3 sets on the wrapped `swlinux` binary.
#
# Models (Parakeet + cleanup GGUF) are large and NOT in the store; a home-manager
# activation fetches them to $XDG_DATA_HOME/swlinux/models. See the alarm host.
{
  lib,
  python3,
  src,
  gobject-introspection,
  wrapGAppsHook3,
  makeWrapper,
  gtk3,
  gtk-layer-shell,
  wtype,
  wl-clipboard,
  hyprland,
  pipewire,
}:
let
  # self-contained python for hud.py (only needs gi; GtkLayerShell/Gtk typelibs
  # arrive via the inherited GI_TYPELIB_PATH from the wrapped daemon).
  hudPython = python3.withPackages (ps: [ ps.pygobject3 ]);
in
python3.pkgs.buildPythonApplication {
  pname = "swlinux";
  version = "0.1.0";
  inherit src;
  pyproject = true;

  build-system = [ python3.pkgs.hatchling ];

  nativeBuildInputs = [ gobject-introspection wrapGAppsHook3 makeWrapper ];
  buildInputs = [ gtk3 gtk-layer-shell ];

  dependencies = with python3.pkgs; [
    sherpa-onnx
    llama-cpp-python
    soundfile
    numpy
    pygobject3
  ];

  # sherpa-onnx/llama-cpp pin loose versions; skip the runtime-deps check.
  dontCheckRuntimeDeps = true;

  # Run the pytest suite at build time (pure glue logic; no models/hardware).
  nativeCheckInputs = [ python3.pkgs.pytestCheckHook ];

  # Let wrapGAppsHook3 assemble GI_TYPELIB_PATH etc., but add our own env: the
  # HUD interpreter and the external CLIs the daemon shells out to.
  dontWrapGApps = true;
  preFixup = ''
    makeWrapperArgs+=(
      "''${gappsWrapperArgs[@]}"
      --set SWLINUX_HUD_PYTHON ${hudPython}/bin/python3
      --prefix PATH : ${lib.makeBinPath [ wtype wl-clipboard hyprland pipewire ]}
    )
  '';

  meta = {
    description = "Local Wayland dictation: Parakeet STT + local-LLM cleanup";
    homepage = "https://github.com/edwinhu/superwhisper-linux";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "swlinux";
  };
}
