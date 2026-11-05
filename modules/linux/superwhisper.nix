# superwhisper — Superwhisper for Linux (superwhisper.com/linux), the portable
# release archive from gh:superultrainc/superwhisper-linux-releases.
#
# Built for Omarchy and unpatched on purpose (dontFixup): the binaries link the
# Arch system libs (gtk4, vulkan, xkbcommon), the fcitx5 addon is dlopen'd by
# pacman's fcitx5 and must match its libFcitx5Core, and the helper scripts need
# /usr/bin/python3 with python-gobject + gtk4-layer-shell. Would need
# autoPatchelf + a python env on NixOS.
#
# Replaces the vendor install.sh, which installs into ~/.local/share/superwhisper
# and self-updates every 6h. Here the version is pinned and updates are a bump:
# `version` + both hashes (tux.superwhisper.com/stable.json lists the sha256s).
# The user service, launcher entry and fcitx5 addon live in
# hosts/linux/omarchy/default.nix.
{ lib, stdenvNoCC, fetchurl, zstd }:

let
  version = "1.2.0";

  platforms = {
    x86_64-linux.hash = "sha256-KLxXWO1s9CRouX75QOwqlrEU5rbqA7yywEvGeIV9AvA=";
    aarch64-linux.hash = "sha256-sA448gPdW4xjS3bf2VwxEoWP3myQTniKN0GYHA6uafg=";
  };

  arch = stdenvNoCC.hostPlatform.parsed.cpu.name;
  platformInfo = platforms.${stdenvNoCC.hostPlatform.system}
    or (throw "superwhisper: unsupported platform ${stdenvNoCC.hostPlatform.system}");

in stdenvNoCC.mkDerivation {
  pname = "superwhisper";
  inherit version;

  src = fetchurl {
    url = "https://github.com/superultrainc/superwhisper-linux-releases/releases/download/v${version}/superwhisper-linux-${arch}-${version}.tar.zst";
    inherit (platformInfo) hash;
  };

  nativeBuildInputs = [ zstd ];

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    (sha256sum -c MANIFEST.sha256 >/dev/null)
    app=$out/share/superwhisper/app
    mkdir -p $app $out/bin
    cp -a app/. $app/

    # run.sh resolves its own dir, so exec it in place. /usr/bin first: every
    # tool it shells out to (python3+gi, pactl, wl-copy, notify-send, fcitx5)
    # is a pacman dependency. SW_CLI is the path it hands to Hyprland binds
    # and activation links; its default is the vendor's ~/.local/bin copy.
    # SUPERWHISPER_HYPR_BINDINGS is the file `shortcuts apply` appends its
    # dofile block to. The default, hypr/bindings.lua, is a dotfiles symlink
    # that the atomic rewrite replaces with a plain file; this one is local,
    # and bindings.lua loads it when present.
    cat > $out/bin/superwhisper <<EOF
    #!/bin/sh
    export PATH="/usr/bin:\$PATH"
    export SW_CLI="$out/bin/superwhisper"
    export SUPERWHISPER_HYPR_BINDINGS="\''${SUPERWHISPER_HYPR_BINDINGS:-\''${XDG_CONFIG_HOME:-\$HOME/.config}/hypr/superwhisper.lua}"
    exec "$app/run.sh" "\$@"
    EOF
    chmod 0755 $out/bin/superwhisper

    for png in $app/assets/app-icon/*.png; do
      size=$(basename "$png" .png)
      [[ "$size" =~ ^[0-9]+$ ]] || continue
      install -Dm0644 "$png" $out/share/icons/hicolor/''${size}x''${size}/apps/superwhisper.png
    done
    install -Dm0644 $app/assets/linux-status/SuperwhisperTUI.ttf \
      $out/share/fonts/truetype/superwhisper/SuperwhisperTUI.ttf

    sed "s|@LIBRARY@|$app/lib/fcitx5/libsuperwhisper-fcitx5|" \
      $app/assets/fcitx5/superwhisper.conf.in > $out/share/superwhisper/fcitx5-addon.conf
    runHook postInstall
  '';

  meta = {
    description = "Superwhisper dictation for Linux (Wayland: Hyprland, KDE, GNOME)";
    homepage = "https://superwhisper.com/linux";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "superwhisper";
    platforms = builtins.attrNames platforms;
  };
}
