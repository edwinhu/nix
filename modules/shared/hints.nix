# Hints — "Click, scroll, and drag with your keyboard" (gh:AlfredoSequeida/hints).
#
# A GTK4 desktop overlay that lets you drive any Linux GUI (X11 or Wayland) with
# keyboard hints, à la vimium. Not in nixpkgs, so we build it from source here.
#
# Two entry points ship: `hints` (the CLI/overlay) and `hintsd` (the daemon that
# listens for the global hotkey via evdev — it needs read access to /dev/input,
# i.e. the invoking user in the `input` group, which is host/OS config outside
# this derivation).
#
# The upstream setup.py has a PostInstallCommand that writes a per-user
# systemd service into ~/.config during `pip install`; that both fails in the
# build sandbox and has no place in a Nix store path, so postPatch strips it.
{
  lib,
  python3,
  fetchFromGitHub,
  gobject-introspection,
  wrapGAppsHook4,
  pkg-config,
  cairo,
  gtk4,
  gtk4-layer-shell,
  libwnck,
  grim,
  wl-clipboard,
  makeWrapper,
}:

python3.pkgs.buildPythonApplication rec {
  pname = "hints";
  version = "0.1.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "AlfredoSequeida";
    repo = "hints";
    tag = version;
    hash = "sha256-JhHoXnZeGBu9m2o3cRUky6Nc5uSc1DkS9V8420jEw+o=";
  };

  # Drop the setup.py PostInstallCommand (writes a systemd user service into
  # $HOME at install time — nonsensical for a store build) so a plain setuptools
  # install runs.
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'cmdclass={"install": PostInstallCommand},' ""
  '';

  build-system = [ python3.pkgs.setuptools ];

  nativeBuildInputs = [
    gobject-introspection
    wrapGAppsHook4
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    cairo
    gtk4
    gtk4-layer-shell
    libwnck
  ];

  dependencies = with python3.pkgs; [
    pygobject3
    pillow
    pyscreenshot
    opencv4
    evdev
    dbus-python
    rich
  ];

  # Upstream pins PyGObject==3.50.0 and lists opencv-python (pname opencv4 in
  # nixpkgs); neither matches the runtime-deps check, so relax it.
  dontCheckRuntimeDeps = true;

  # grim (Wayland screenshots) and wl-clipboard are called as external binaries
  # at runtime; make sure they resolve regardless of the user's PATH.
  postFixup = ''
    for b in hints hintsd; do
      wrapProgram $out/bin/$b \
        --prefix PATH : ${lib.makeBinPath [ grim wl-clipboard ]}
    done
  '';

  # No test suite ships; import check is enough via the wrapped binary.
  doCheck = false;

  meta = {
    description = "Navigate Linux GUIs without a mouse using keyboard hints";
    homepage = "https://github.com/AlfredoSequeida/hints";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "hints";
  };
}
