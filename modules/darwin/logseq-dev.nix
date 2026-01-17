{ pkgs, lib, config, user, ... }:

{
  # Install Logseq dev build via activation script
  # Source is the local extracted app from GitHub Actions artifact
  # Built from: https://github.com/logseq/logseq/actions/runs/20808349121
  # Artifact: logseq-darwin-arm64-builds (ID: 5059318899)

  system.activationScripts.preActivation.text = ''
    # Install Logseq dev version to /Applications
    # This runs BEFORE home-manager activation (including dock setup)
    LOGSEQ_SOURCE="${config.users.users.${user}.home}/nix/apps/logseq-dev/Logseq.app"
    LOGSEQ_DEST="/Applications/Logseq.app"

    if [ -d "$LOGSEQ_SOURCE" ]; then
      # Verify code signature before installing
      if /usr/bin/codesign -vv "$LOGSEQ_SOURCE" 2>/dev/null; then
        echo "Installing Logseq dev build..."
        # Remove old version if it exists
        if [ -d "$LOGSEQ_DEST" ]; then
          rm -rf "$LOGSEQ_DEST"
        fi
        # Copy new version
        cp -R "$LOGSEQ_SOURCE" "$LOGSEQ_DEST"
        # Fix permissions
        chmod -R u+w "$LOGSEQ_DEST"
        # Remove quarantine attribute if present
        /usr/bin/xattr -cr "$LOGSEQ_DEST" 2>/dev/null || true
        echo "Logseq dev build installed to $LOGSEQ_DEST"
      else
        echo "ERROR: Logseq source at $LOGSEQ_SOURCE has invalid code signature!"
        echo "Re-download the artifact: gh run download 20808349121 -n logseq-darwin-arm64-builds -R logseq/logseq"
        echo "Then extract: unzip -o Logseq-darwin-arm64-*.zip"
      fi
    else
      echo "Warning: Logseq source not found at $LOGSEQ_SOURCE"
    fi
  '';
}
