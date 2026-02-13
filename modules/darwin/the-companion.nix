# the-companion - Web UI for Claude Code agents
# Installed via: bun install -g the-companion
# Served on tailnet via tailscale serve
{ pkgs, user, ... }:

let
  bunBin = "/Users/${user}/.bun/bin";
  tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  port = 3456;
in
{
  # Launchd service to run the-companion server
  launchd.user.agents.the-companion = {
    serviceConfig = {
      ProgramArguments = [
        "${bunBin}/the-companion"
        "start"
        "--port"
        (toString port)
      ];
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion.log";
      StandardErrorPath = "/tmp/the-companion.log";
      EnvironmentVariables = {
        PATH = "/Users/${user}/.local/bin:/Users/${user}/.nix-profile/bin:${bunBin}:${pkgs.bun}/bin:${pkgs.nodejs}/bin:/usr/bin:/bin";
        HOME = "/Users/${user}";
        NODE_ENV = "production";
      };
    };
  };

  # Launchd service to expose the-companion on the tailnet
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
