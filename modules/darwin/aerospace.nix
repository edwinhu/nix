{ pkgs, user, ... }:
{
  # Install aerospace package (manage config via dotfiles)
  environment.systemPackages = [ pkgs.aerospace ];

  # Create launchd service to start aerospace on login
  launchd.user.agents.aerospace = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.aerospace}/Applications/AeroSpace.app/Contents/MacOS/AeroSpace"
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Interactive";
    };
  };
}
