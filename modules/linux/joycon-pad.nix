# joycon-pad — a Nintendo Switch Joy-Con (L) as a macro pad for swlinux + limux.
# Single-file evdev daemon fetched from gh:edwinhu/joycon-pad via the
# joycon-pad-src flake input. Reads the Bluetooth-paired Joy-Con (in-tree
# hid-nintendo driver) and drives swlinux (ZL → dictation), limux (SL/SR → tab
# switch, X/Y → panes), the pointer (stick → ydotool mousemove), arrows (d-pad),
# and an Alt-Tab switcher (Capture hold + stick flick).
#
# Runs as a user service (see hosts/linux/omarchy). /dev/input reads + rumble
# work because `eh` is in the `input` group — the same grant xremap/ydotoold use.
# Pairing needs a one-time `ClassicBondedOnly=false` in /etc/bluetooth/input.conf
# (Arch-managed, not nix — see the repo's README/pair-joycon.sh): Joy-Cons pair
# but don't bond, and BlueZ refuses non-bonded HID by default.
{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  ydotool,
  src,
}:
let
  # evdev is the only runtime dep; from nixpkgs (no uv at runtime).
  pyEnv = python3.withPackages (ps: [ ps.evdev ]);
in
stdenvNoCC.mkDerivation {
  pname = "joycon-pad";
  version = "0.1.0";
  inherit src;

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;

  # The PEP-723 shebang (uv run) is stripped: we wrap the module under a pinned
  # python that already has evdev, and put ydotool on PATH for pointer/keys.
  # swlinux + limux are added to PATH by the systemd unit (they're user pkgs).
  installPhase = ''
    runHook preInstall
    install -Dm644 joycon_pad.py $out/libexec/joycon-pad/joycon_pad.py
    makeWrapper ${pyEnv}/bin/python3 $out/bin/joycon-pad \
      --add-flags $out/libexec/joycon-pad/joycon_pad.py \
      --prefix PATH : ${lib.makeBinPath [ ydotool ]}
    runHook postInstall
  '';

  meta = {
    description = "Nintendo Switch Joy-Con as a macro pad for swlinux + limux";
    homepage = "https://github.com/edwinhu/joycon-pad";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "joycon-pad";
  };
}
