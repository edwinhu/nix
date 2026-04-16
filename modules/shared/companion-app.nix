# Companion.app — minimal Electron wrapper for the companion web UI
# Loads http://localhost:3456 in a standalone window with its own
# bundle ID, Dock icon, and Cmd+Tab presence.
{ lib, stdenv, electron, makeWrapper, python3, librsvg, imagemagick }:

let
  iconSvg = /Users/vwh7mb/projects/companion/web/public/favicon.svg;
  themeCssRaw = builtins.readFile ./companion-catppuccin.css;
  fontDir =
    let
      home = builtins.getEnv "HOME";
      fontPath = builtins.toPath "${home}/.nix-profile/share/fonts/truetype";
    in
      if home != "" && builtins.pathExists fontPath then builtins.path {
        path = fontPath;
        name = "companion-maple-fonts";
      } else null;
  mainJs = builtins.toFile "main.js" ''
    const { app, BrowserWindow, shell } = require('electron');
    const fs = require('node:fs');
    const path = require('node:path');
    const { pathToFileURL } = require('node:url');
    const URL = 'http://localhost:3456';
    let win;

    function loadThemeCss() {
      try {
        const themePath = path.join(process.resourcesPath, 'companion-theme.css');
        const fontsDir = pathToFileURL(path.join(process.resourcesPath, 'fonts')).href;
        const raw = fs.readFileSync(themePath, 'utf8');
        return raw.replaceAll('url("/fonts/', `url("''${fontsDir}/`);
      } catch (error) {
        console.error('[companion-app] Failed to load packaged theme:', error);
        return "";
      }
    }

    const themeCss = loadThemeCss();

    async function applyTheme() {
      if (!win || !themeCss) return;
      try {
        await win.webContents.insertCSS(themeCss);
      } catch (error) {
        console.error('[companion-app] Failed to inject theme:', error);
      }
    }

    function createWindow() {
      win = new BrowserWindow({
        width: 1200,
        height: 900,
        title: 'Companion',
        backgroundColor: '#1e1e2e',
        webPreferences: { nodeIntegration: false, contextIsolation: true },
      });
      win.loadURL(URL);
      win.webContents.on('did-finish-load', applyTheme);
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
  nativeBuildInputs = [ makeWrapper python3 librsvg imagemagick ];

  installPhase = ''
    runHook preInstall

    # Copy Electron.app as Companion.app
    mkdir -p $out/Applications
    cp -R ${electron}/Applications/Electron.app $out/Applications/Companion.app
    chmod -R u+w $out/Applications/Companion.app

    APP=$out/Applications/Companion.app/Contents

    # Generate a proper macOS icon: Catppuccin-dark squircle background with
    # the Companion favicon composited on top at ~80% of the canvas.
    iconset="$(mktemp -d)/Companion.iconset"
    mkdir -p "$iconset"
    tmp="$(mktemp -d)"

    # 1. Render favicon at 640 wide preserving aspect ratio (transparent bg)
    ${librsvg}/bin/rsvg-convert -w 520 ${iconSvg} -o "$tmp/logo.png"

    # 2. Build 1024x1024 Catppuccin-dark squircle background
    ${imagemagick}/bin/magick -size 1024x1024 xc:none \
      -fill '#1e1e2e' \
      -draw 'roundrectangle 100,100 923,923 149,149' \
      "$tmp/bg.png"

    # 3. Composite logo centered onto the background -> master 1024x1024
    ${imagemagick}/bin/magick "$tmp/bg.png" "$tmp/logo.png" -gravity center -composite \
      "$iconset/icon_512x512@2x.png"

    # 4. Generate remaining iconset sizes from the master
    cp "$iconset/icon_512x512@2x.png" "$iconset/icon_512x512.png"
    for entry in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x"; do
      set -- $entry
      ${imagemagick}/bin/magick "$iconset/icon_512x512@2x.png" -resize "$1x$1" "$iconset/$2.png"
    done

    /usr/bin/iconutil -c icns "$iconset" -o "$APP/Resources/electron.icns"

    # Replace app resources with our main.js
    rm -rf $APP/Resources/default_app.asar
    mkdir -p $APP/Resources/app
    cp ${mainJs} $APP/Resources/app/main.js
    echo '{"name":"companion","version":"1.0.0","main":"main.js"}' > $APP/Resources/app/package.json

    # Bundle the custom theme and fonts with the desktop wrapper so the
    # localhost server stays unmodified.
    cp ${builtins.toFile "companion-theme.css" themeCssRaw} $APP/Resources/companion-theme.css
    mkdir -p $APP/Resources/fonts
    ${lib.optionalString (fontDir != null) ''
      for weight in Regular Bold Italic BoldItalic; do
        if [ -f "${fontDir}/MapleMono-NF-$weight.ttf" ]; then
          cp "${fontDir}/MapleMono-NF-$weight.ttf" "$APP/Resources/fonts/"
        fi
      done
    ''}

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
