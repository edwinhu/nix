# Companion.app — minimal Electron wrapper for the companion web UI
# Loads http://localhost:3456 in a standalone window with its own
# bundle ID, Dock icon, and Cmd+Tab presence.
{ lib, stdenv, electron, makeWrapper, python3 }:

let
  mainJs = builtins.toFile "main.js" ''
    const { app, BrowserWindow, shell } = require('electron');
    const URL = 'http://localhost:3456';
    let win;

    function createWindow() {
      win = new BrowserWindow({
        width: 1200,
        height: 900,
        title: 'Companion',
        webPreferences: { nodeIntegration: false, contextIsolation: true },
      });
      win.loadURL(URL);
      win.webContents.setWindowOpenHandler(({ url }) => {
        if (!url.startsWith('http://localhost:3456')) {
          shell.openExternal(url);
          return { action: 'deny' };
        }
        return { action: 'allow' };
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
    plist["CFBundleDisplayName"] = "Companion"
    plist["CFBundleName"] = "Companion"
    plist["CFBundleIdentifier"] = "com.companion.app"
    plist["CFBundleExecutable"] = "Companion"
    with open(path, "wb") as f:
        plistlib.dump(plist, f)
  '';
in stdenv.mkDerivation {
  pname = "companion-app";
  version = "1.0.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper python3 ];

  installPhase = ''
    runHook preInstall

    # Copy Electron.app as Companion.app
    mkdir -p $out/Applications
    cp -R ${electron}/Applications/Electron.app $out/Applications/Companion.app
    chmod -R u+w $out/Applications/Companion.app

    APP=$out/Applications/Companion.app/Contents

    # Replace app resources with our main.js
    rm -rf $APP/Resources/default_app.asar
    mkdir -p $APP/Resources/app
    cp ${mainJs} $APP/Resources/app/main.js
    echo '{"name":"companion","version":"1.0.0","main":"main.js"}' > $APP/Resources/app/package.json

    # Update Info.plist via python (PlistBuddy not available in sandbox)
    python3 ${plistPatch} $APP/Info.plist

    # Rename the executable
    mv $APP/MacOS/Electron $APP/MacOS/Companion

    # CLI wrapper
    mkdir -p $out/bin
    makeWrapper $APP/MacOS/Companion $out/bin/companion-app

    runHook postInstall
  '';

  meta = {
    description = "Companion web UI as standalone Electron app";
    platforms = lib.platforms.darwin;
    mainProgram = "companion-app";
  };
}
