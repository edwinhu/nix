{ pkgs, user, ... }:
{
  # Install aerospace package (manage config via dotfiles)
  environment.systemPackages = [ pkgs.aerospace ];

  # Copy AeroSpace.app to /Applications so macOS TCC accessibility
  # permissions persist across nix rebuilds (TCC ties permissions to
  # the binary path, and nix store paths change on every rebuild).
  system.activationScripts.copyAerospace.text = ''
    echo "Copying AeroSpace.app to /Applications (stable path for TCC permissions)..."
    rm -rf /Applications/AeroSpace.app
    cp -RL "${pkgs.aerospace}/Applications/AeroSpace.app" /Applications/AeroSpace.app
    chmod -R u+w /Applications/AeroSpace.app
  '';

  # Create launchd service to start aerospace on login (from stable path)
  launchd.user.agents.aerospace = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/bin/open"
        "-a"
        "/Applications/AeroSpace.app"
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Interactive";
    };
  };
}
