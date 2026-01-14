{ pkgs, user, ... }:
{
  # Install syncthing-macos package (manage config via app)
  environment.systemPackages = [ pkgs.syncthing-macos ];

  # Create launchd service to start syncthing on login
  launchd.user.agents.syncthing = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/bin/open"
        "-a"
        "${pkgs.syncthing-macos}/Applications/Syncthing.app"
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Background";
    };
  };
}
