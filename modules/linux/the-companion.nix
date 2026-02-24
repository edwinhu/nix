# the-companion - Web UI for Claude Code agents
# Runs as systemd user service, exposed on tailnet via tailscale serve
{ pkgs, user, ... }:

let
  port = 3456;
in
{
  systemd.user.services.the-companion = {
    Unit = {
      Description = "The Companion - Web UI for Claude Code agents";
      After = [ "network.target" ];
    };
    Service = {
      ExecStart = "${pkgs.the-companion}/bin/the-companion serve --port ${toString port}";
      Restart = "always";
      RestartSec = 5;
      Environment = [
        "PATH=/home/${user}/.local/bin:/home/${user}/.nix-profile/bin:${pkgs.bun}/bin:${pkgs.nodejs}/bin:/usr/bin:/bin"
        "HOME=/home/${user}"
        "NODE_ENV=production"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.the-companion-tailserve = {
    Unit = {
      Description = "Tailscale serve for The Companion";
      After = [ "the-companion.service" ];
      Requires = [ "the-companion.service" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/usr/bin/tailscale serve --bg ${toString port}";
      ExecStop = "/usr/bin/tailscale serve off";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
