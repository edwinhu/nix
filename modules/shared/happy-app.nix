# Happy.app — minimal Electron wrapper for app.happy.engineering.
# Standalone window with its own bundle id, dock icon, and Cmd+Tab presence.
{ lib, stdenv, electron, makeWrapper, python3, fetchurl, imagemagick }:

let
  appUrl = "https://app.happy.engineering/";
  # Tauri desktop icon from upstream slopus/happy (1024x1024, RGBA).
  iconSrc = fetchurl {
    url = "https://raw.githubusercontent.com/slopus/happy/main/packages/happy-app/sources/assets/images/icon-tauri.png";
    hash = "sha256-vYn+RiymfP9rSGex4BCKLmV+vIsXVQ7MpfhZ/f0H11A=";
  };
  mainJs = builtins.toFile "main.js" ''
    const { app, BrowserWindow, shell } = require('electron');
    const APP_URL = '${appUrl}';
    const ALLOWED_HOST = new URL(APP_URL).host;
    let win;

    function createWindow() {
      win = new BrowserWindow({
        width: 1200,
        height: 900,
        title: 'Happy',
        backgroundColor: '#1e1e2e',
        webPreferences: { nodeIntegration: false, contextIsolation: true },
      });
      win.loadURL(APP_URL);
      // Same-host links stay in the window; everything else opens externally.
      win.webContents.setWindowOpenHandler(({ url }) => {
        try {
          if (new URL(url).host === ALLOWED_HOST) return { action: 'allow' };
        } catch {}
        shell.openExternal(url);
        return { action: 'deny' };
      });
      win.on('closed', () => { win = null; });
    }

    app.on('ready', createWindow);
    app.on('activate', () => {
      if (win === null) createWindow();
      else { win.show(); win.focus(); }
    });
    app.on('window-all-closed', () => {
      if (process.platform !== 'darwin') app.quit();
    });
  '';

  plistPatch = builtins.toFile "patch-plist.py" ''
    import plistlib, sys
    path = sys.argv[1]
    with open(path, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleDisplayName"] = "Happy"
    plist["CFBundleName"] = "Happy"
    plist["CFBundleIdentifier"] = "com.happy.app"
    plist["CFBundleExecutable"] = "Happy"
    with open(path, "wb") as f:
        plistlib.dump(plist, f)
  '';
in stdenv.mkDerivation {
  pname = "happy-app";
  version = "1.0.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper python3 imagemagick ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications
    cp -R ${electron}/Applications/Electron.app $out/Applications/Happy.app
    chmod -R u+w $out/Applications/Happy.app

    APP=$out/Applications/Happy.app/Contents

    # Build macOS iconset from the upstream 1024x1024 desktop icon.
    iconset="$(mktemp -d)/Happy.iconset"
    mkdir -p "$iconset"
    cp ${iconSrc} "$iconset/icon_512x512@2x.png"
    cp "$iconset/icon_512x512@2x.png" "$iconset/icon_512x512.png"
    for entry in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x"; do
      set -- $entry
      ${imagemagick}/bin/magick "$iconset/icon_512x512@2x.png" -resize "$1x$1" "$iconset/$2.png"
    done

    /usr/bin/iconutil -c icns "$iconset" -o "$APP/Resources/electron.icns"

    rm -rf $APP/Resources/default_app.asar
    mkdir -p $APP/Resources/app
    cp ${mainJs} $APP/Resources/app/main.js
    echo '{"name":"happy","version":"1.0.0","main":"main.js"}' > $APP/Resources/app/package.json

    python3 ${plistPatch} $APP/Info.plist

    mv $APP/MacOS/Electron $APP/MacOS/Happy

    mkdir -p $out/bin
    makeWrapper $APP/MacOS/Happy $out/bin/happy-app

    runHook postInstall
  '';

  meta = {
    description = "Happy web UI as a standalone Electron app";
    platforms = lib.platforms.darwin;
    mainProgram = "happy-app";
  };
}
