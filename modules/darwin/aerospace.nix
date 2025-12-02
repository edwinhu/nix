{ pkgs, user, ... }:
{
  # Install aerospace package (manage config via dotfiles)
  environment.systemPackages = [ pkgs.aerospace ];

  # Create launchd service to start aerospace on login
  launchd.user.agents.aerospace = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/bin/open"
        "-a"
        "${pkgs.aerospace}/Applications/AeroSpace.app"
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Interactive";
    };
  };
}
