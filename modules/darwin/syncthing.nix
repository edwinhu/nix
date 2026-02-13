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
