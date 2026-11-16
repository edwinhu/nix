# herdr-app — the Herdr desktop app (herdr.dev) plus herdr-core (`hc`), the
# background runtime its terminals live in. Not the `herdr` TUI, which mise
# installs (scripts/setup-ai-tools.sh).
#
# Replaces the vendor install.sh (~/.local/share/herdr-app, ~/.local/bin). The
# app checks hourly and offers updates in its corner; here they are a bump:
# both versions + hashes, from releases.herdr.dev/{app,core}/latest.json
# (`nix hash convert --to sri <sha256>`). Keep core >= the app's core_min.
#
# Linux: herdr-app links the Arch system libs (gpui: vulkan, wayland,
# xkbcommon, fontconfig), so it is installed unpatched (dontFixup); herdr-core
# is static. The launcher entry is in hosts/linux/omarchy/default.nix.
#
# macOS: both tarballs are signed .app bundles (Herdr.app, Herdr Core.app),
# installed as-is so the signatures hold. bin/herdr-core and hc point INTO
# Herdr Core.app: Full Disk Access is granted to that bundle, and the app finds
# its core on PATH.
{ lib, stdenvNoCC, fetchurl }:

let
  appVersion = "0.1.13";
  coreVersion = "0.1.18";

  platforms = {
    x86_64-linux = {
      app = "sha256-d7C+cqRsoUuzZzZaBBZGQfkUs6aXErrDkdOcVqlZvvQ=";
      core = "sha256-Wy+Xy0sqnXprLMWUJiggPtn7t8wMK0sJrYpvVkjiRrc=";
    };
    aarch64-linux = {
      app = "sha256-LluwXEfP+60BitNCF+pMgWR21+uEJpL3QHmMkCDwKB4=";
      core = "sha256-zzM5PPlQu3Y3NNw+FmEKudr4SSORpO8N5WAmzX91KFM=";
    };
    aarch64-darwin = {
      app = "sha256-9d0LyBqp72HPv7bvn9v0/n9mTU7Gdu4NyI8TzJdZ0NA=";
      core = "sha256-d9ivCS4lrmUPRCTW2tJ1FPaRahHYB/sHUoWM0nwh5Pw=";
    };
  };

  isDarwin = stdenvNoCC.hostPlatform.isDarwin;
  os = if isDarwin then "macos" else "linux";
  arch = stdenvNoCC.hostPlatform.parsed.cpu.name;
  hashes = platforms.${stdenvNoCC.hostPlatform.system}
    or (throw "herdr-app: unsupported platform ${stdenvNoCC.hostPlatform.system}");

  core = fetchurl {
    url = "https://releases.herdr.dev/core/${coreVersion}/herdr-core-${os}-${arch}.tar.gz";
    hash = hashes.core;
  };

in stdenvNoCC.mkDerivation {
  pname = "herdr-app";
  version = appVersion;

  src = fetchurl {
    url = "https://releases.herdr.dev/app/${appVersion}/herdr-app-${os}-${arch}.tar.gz";
    hash = hashes.app;
  };

  sourceRoot = ".";
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir core && tar -xzf ${core} -C core
  '' + (if isDarwin then ''
    mkdir -p $out/Applications $out/bin
    cp -R Herdr.app "core/Herdr Core.app" $out/Applications/
    ln -s "$out/Applications/Herdr.app/Contents/MacOS/Herdr" $out/bin/herdr-app
    ln -s "$out/Applications/Herdr Core.app/Contents/MacOS/herdr-core" $out/bin/herdr-core
    ln -s herdr-core $out/bin/hc
  '' else ''
    install -Dm0755 herdr-app/herdr-app $out/bin/herdr-app
    install -Dm0644 herdr-app/herdr-app.svg $out/share/icons/hicolor/scalable/apps/herdr-app.svg
    install -Dm0755 core/herdr-core $out/bin/herdr-core
    ln -s herdr-core $out/bin/hc
  '') + ''
    runHook postInstall
  '';

  meta = {
    description = "Herdr desktop app and herdr-core terminal runtime";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "herdr-app";
    platforms = builtins.attrNames platforms;
  };
}
