# the-companion - Web UI for Claude Code agents
# Runs as launchd service, exposed on tailnet via tailscale serve
{ pkgs, user, ... }:

let
  tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  port = 3456;
in
{
  launchd.user.agents.the-companion = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.the-companion}/bin/the-companion"
        "serve"
        "--port"
        (toString port)
      ];
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion.log";
      StandardErrorPath = "/tmp/the-companion.log";
      EnvironmentVariables = {
        PATH = "/Users/${user}/.local/bin:/Users/${user}/.nix-profile/bin:${pkgs.bun}/bin:${pkgs.nodejs}/bin:/usr/bin:/bin";
        HOME = "/Users/${user}";
        NODE_ENV = "production";
      };
    };
  };

  launchd.user.agents.the-companion-tailserve = {
    serviceConfig = {
      ProgramArguments = [
        tailscale
        "serve"
        "--bg"
        (toString port)
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion-tailserve.log";
      StandardErrorPath = "/tmp/the-companion-tailserve.log";
    };
  };
}
