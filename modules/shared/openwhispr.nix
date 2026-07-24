# OpenWhispr — open-source local dictation + AI meeting notes (Electron),
# fetched as the upstream release AppImage. This is the Linux stand-in for
# granola, which is macOS-only (see modules/darwin/casks.nix).
#
# We extract the AppImage, patch the packed `app.asar` in place (see
# `patchedApp` below), then wrap the patched tree in an FHS runtime with
# appimageTools.wrapAppImage — the same FHS/no-libfuse/no-system-Electron
# runtime wrapType2 would build, just fed a directory we control instead of the
# raw AppImage. The nixGLIntel wrap + --no-sandbox (Chromium can't use the
# non-setuid store chrome-sandbox) is applied one level up, in the flake
# overlay, exactly like hylo/beeper.
#
# Only the icon is installed here; the .desktop is declared in the omarchy host
# (xdg.desktopEntries.openwhispr) so its Exec points at the nixGL-wrapped
# `openwhispr` on PATH rather than the AppImage's bundled `Exec=AppRun`.
#
# Update flow: bump `version`, then take the new hash from
#   gh release view --repo OpenWhispr/openwhispr --json assets \
#     --jq '.assets[] | select(.name | endswith("x86_64.AppImage")) | .digest'
# and convert it: `nix hash convert --hash-algo sha256 --to sri <sha256>`.
# After a bump, re-verify the meeting-toast patch below still applies (the
# builder asserts the target text exists, so a moved/renamed block fails the
# build loudly rather than silently shipping an unpatched app).
{ lib, fetchurl, appimageTools, runCommand, python3, pulseaudio, procps, noto-fonts-color-emoji
, coreutils, hyprland, wtype, ydotool, wl-clipboard, xdotool }:

let
  pname = "openwhispr";
  version = "1.7.5";

  src = fetchurl {
    name = "openwhispr-${version}.AppImage";
    url = "https://github.com/OpenWhispr/openwhispr/releases/download/v${version}/OpenWhispr-${version}-linux-x86_64.AppImage";
    hash = "sha256-InmwYfIw+CfvCYx2DwZDIS9l/yj+MK5m7AUoT0TvbO4=";
  };

  # The raw extracted AppImage tree (AppRun, the Electron runtime, native
  # helpers, resources/app.asar, usr/ icons). Used both as the source for the
  # asar patch below and, unmodified, for the icon install.
  contents = appimageTools.extract { inherit pname version src; };

  # Meeting-toast click fix.
  #
  # The "Start meeting recording?" prompt is a custom transparent Electron
  # BrowserWindow, not a freedesktop notification. Its renderer toggles the
  # window between click-through and interactive on mouse enter/leave via
  # WindowManager.setNotificationInteractivity(), whose non-interactive branch
  # calls `setIgnoreMouseEvents(true, { forward: true })`.
  #
  # On wlroots compositors (Hyprland/Sway, which this host runs) that forward
  # mode is a no-op: the compositor delivers NO forwarded mouse-move events to a
  # click-through XWayland surface, so the renderer's mouseenter — the only path
  # that flips the window back to interactive — can never fire. After the first
  # onMouseLeave the toast is click-through forever and its Start/Dismiss buttons
  # stop responding. Verified empirically on Hyprland: a window in that state
  # receives neither forwarded mousemove nor button clicks; a plain interactive
  # overlay receives both. Upstream tracks this as issue #840 (open, unfixed as
  # of 1.7.6; the open PR #1026 addresses a different overlay bug and explicitly
  # notes Hyprland click quirks remain).
  #
  # Fix: neutralize that call so the meeting toast stays interactive on Linux,
  # mirroring what upstream already does for the main panel on Windows
  # ("click-through forwarding is unreliable ... keep the panel interactive").
  # The edit is a byte-for-byte same-length substitution in the packed app.asar
  # blob (`(true, { forward: true })` -> `(false                  )`), so every
  # file offset in the asar header stays valid and the archive needs no
  # repacking — the native unpacked modules alongside it are left untouched.
  #
  # Editing the blob does invalidate the per-file `integrity` hashes
  # electron-builder embeds in the asar header — but those are only enforced when
  # Electron's `EnableEmbeddedAsarIntegrityValidation` fuse is on (index 4 of the
  # FuseV1Options wire), and even then not on Linux today. It is DISABLED in this
  # bundle, so the edited archive loads. The patch script asserts that fuse is
  # off before touching the asar, so a future version that flips it on fails the
  # build here rather than shipping an app that rejects its own asar at startup.
  #
  # The builder also asserts the target call appears the expected number of
  # times, so a future version that reworks it fails the build instead of
  # silently regressing. The tradeoff is that the small (392x92) toast captures
  # clicks over its whole rectangle while visible — strictly better than an
  # unclickable button.
  patchedApp = runCommand "openwhispr-${version}-patched"
    { nativeBuildInputs = [ python3 ]; } ''
    cp -r ${contents} $out
    chmod -R u+w $out
    python3 ${./openwhispr-meeting-toast.patch.py} $out
  '';
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = patchedApp;

  # The meeting-notes feature (the reason this stands in for granola) shells out
  # to `pactl subscribe` to notice a call's audio streams and to `ps` to identify
  # the conferencing app. Neither is in the AppImage's FHS runtime, so without
  # these the app still dictates but silently logs `spawn pactl ENOENT` /
  # `spawn ps ENOENT` and never auto-detects a meeting.
  #
  # coreutils: the Wayland-paste setup checklist probes input-group membership
  # with `spawnSync("groups")`; without `groups` on the FHS PATH the probe
  # errors and the app falsely warns "User must be in the input group" even when
  # the user is (paste itself goes through the host ydotoold either way).
  #
  # Wayland paste path: OpenWhispr probes a set of system tools by bare name via
  # commandExists() and shells out to them — none are bundled in the AppImage.
  # Without them on the FHS PATH, paste-back fails, most visibly in TERMINALS:
  #   - hyprland (hyprctl): `hyprctl activewindow -j` reads the focused window's
  #     class. Missing → windowSignals empty → the app can't tell it's a terminal
  #     → it sends Ctrl+V instead of Ctrl+Shift+V, which terminals ignore, so
  #     dictated text never lands in kitty/alacritty/foot/ghostty/etc.
  #   - wtype / ydotool: the actual keystroke injectors on wlroots (ydotool talks
  #     to the host ydotoold via the inherited YDOTOOL_SOCKET).
  #   - wl-clipboard (wl-copy/wl-paste): clipboard read/write for paste + restore.
  #   - xdotool: XWayland fallback path.
  #
  # noto-fonts-color-emoji: the FHS gets its OWN /usr, so the host's
  # /usr/share/fonts (where Arch keeps NotoColorEmoji.ttf) is invisible inside the
  # sandbox — the FHS had no /usr/share/fonts directory at all, and the only font
  # reachable via the bind-mounted /home was omarchy.ttf. With no emoji font in
  # the search path, emoji render as tofu; most visibly the language pickers in
  # Settings, whose flags are PAIRS of Regional Indicator Symbols (🇺🇸 = U+1F1FA +
  # U+1F1F8), so each flag shows as two empty boxes. Adding the font here puts it
  # at the FHS's /usr/share/fonts, which the host fontconfig already searches.
  extraPkgs = pkgs: [
    pulseaudio procps coreutils
    hyprland wtype ydotool wl-clipboard xdotool
    noto-fonts-color-emoji
  ];

  extraInstallCommands = ''
    install -Dm444 ${contents}/usr/share/icons/hicolor/256x256/apps/open-whispr.png \
      $out/share/icons/hicolor/256x256/apps/openwhispr.png
  '';

  meta = {
    description = "Local-first dictation and AI meeting notes (whisper.cpp)";
    homepage = "https://openwhispr.com";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "openwhispr";
  };
}
