{ pkgs, lib, ... }:

let
  sioyek-with-sync = pkgs.stdenv.mkDerivation {
    pname = "sioyek-with-sync";
    version = "1.0";

    src = pkgs.sioyek;

    buildPhase = ''
      # Create app bundle structure
      mkdir -p "Applications/Sioyek with Sync.app/Contents/"{MacOS,Resources}

      # Extract and convert icon from original Sioyek using macOS sips
      cp ${pkgs.sioyek}/Applications/sioyek.app/Contents/Resources/icon2.ico ./
      /usr/bin/sips -s format icns icon2.ico --out sioyek.icns
      cp sioyek.icns "Applications/Sioyek with Sync.app/Contents/Resources/"

      # Create wrapper script
      cat > "Applications/Sioyek with Sync.app/Contents/MacOS/sioyek-wrapper" << 'EOF'
#!/bin/bash
# Run Sioyek with all passed arguments
${pkgs.sioyek}/bin/sioyek "$@"

# After Sioyek exits, run the sync if sync script exists
SYNC_SCRIPT="/Users/vwh7mb/projects/sioyek-readwise-sync/sync"
if [ -x "$SYNC_SCRIPT" ]; then
    echo "🔄 Syncing highlights to Readwise..."
    "$SYNC_SCRIPT"
    if [ $? -eq 0 ]; then
        echo "✅ Highlights synced successfully!"
    else
        echo "❌ Sync failed - check logs"
    fi
fi
EOF
      chmod +x "Applications/Sioyek with Sync.app/Contents/MacOS/sioyek-wrapper"

      # Create Info.plist
      cat > "Applications/Sioyek with Sync.app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>pdf</string>
			</array>
			<key>CFBundleTypeName</key>
			<string>PDF Document</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
		</dict>
	</array>
	<key>CFBundleExecutable</key>
	<string>sioyek-wrapper</string>
	<key>CFBundleIdentifier</key>
	<string>com.sioyek.readwise-sync</string>
	<key>CFBundleName</key>
	<string>Sioyek with Sync</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.10</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>CFBundleDisplayName</key>
	<string>Sioyek with Sync</string>
	<key>CFBundleIconFile</key>
	<string>sioyek</string>
</dict>
</plist>
EOF
    '';

    installPhase = ''
      # Copy the app bundle to output
      mkdir -p "$out/Applications/"
      cp -r "Applications/Sioyek with Sync.app" "$out/Applications/"
    '';

    meta = with lib; {
      description = "Sioyek PDF reader with Readwise sync integration";
      platforms = platforms.darwin;
    };
  };
in
{
  environment.systemPackages = [ sioyek-with-sync ];

  # Create shell alias to use the app bundle
  environment.shellAliases = {
    sioyek = "/Applications/Sioyek\\ with\\ Sync.app/Contents/MacOS/sioyek-wrapper";
  };
}