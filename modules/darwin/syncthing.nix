{ pkgs, user, ... }:
{
  # Install syncthing-macos package (manage config via app)
  environment.systemPackages = [ pkgs.syncthing-macos ];

  # Copy to /Applications for stable path (avoids nix store path changes)
  system.activationScripts.copySyncthing.text = ''
    echo "Copying Syncthing.app to /Applications (stable path)..."
    rm -rf /Applications/Syncthing.app
    cp -RL "${pkgs.syncthing-macos}/Applications/Syncthing.app" /Applications/Syncthing.app
    chmod -R u+w /Applications/Syncthing.app
    # Ad-hoc sign: an unsigned copy breaks the TCC Documents grant on every
    # rebuild (grant is pinned to the binary hash), and macOS then hangs
    # Syncthing's open() of ~/Documents instead of denying it. The app also
    # needs Full Disk Access in System Settings (one-time, survives signing).
    /usr/bin/codesign --force --deep -s - /Applications/Syncthing.app 2>/dev/null || true
  '';

  # Create launchd service to start syncthing on login (from stable path)
  launchd.user.agents.syncthing = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/bin/open"
        "-a"
        "/Applications/Syncthing.app"
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Background";
    };
  };
}
