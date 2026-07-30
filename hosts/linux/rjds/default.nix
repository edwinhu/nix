{ config, pkgs, lib, user, nix-secrets, ... }:

let
  giteaDir = "${config.home.homeDirectory}/.config/gitea";
  docker = "/usr/bin/docker";
  tailscale = "/usr/bin/tailscale";
  waitForTailscale = pkgs.writeShellScript "wait-for-rjds-tailscale" ''
    set -eu
    for attempt in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${pkgs.iproute2}/bin/ip address show tailscale0 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "100.70.33.29"; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 2
    done
    echo "Tailscale address 100.70.33.29 is unavailable" >&2
    exit 1
  '';
  serveGitea = pkgs.writeShellScript "serve-gitea" ''
    set -eu
    for attempt in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${pkgs.curl}/bin/curl --fail --silent http://127.0.0.1:3000/api/healthz >/dev/null; then
        exec ${tailscale} serve --bg --yes --https=443 http://127.0.0.1:3000
      fi
      ${pkgs.coreutils}/bin/sleep 2
    done
    echo "Gitea did not become healthy" >&2
    exit 1
  '';
in
{
  imports = [
    ../../../modules/linux/home-manager.nix
    ../../../modules/shared/home-secrets.nix
  ];

  home = {
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;

  age.secrets = {
    gitea-secret-key = {
      file = "${nix-secrets}/gitea-secret-key.age";
      mode = "400";
    };
    gitea-internal-token = {
      file = "${nix-secrets}/gitea-internal-token.age";
      mode = "400";
    };
    gitea-lfs-jwt-secret = {
      file = "${nix-secrets}/gitea-lfs-jwt-secret.age";
      mode = "400";
    };
  };

  home.activation.giteaDeploymentFiles =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "${giteaDir}" /data/${user}/gitea
      # The container drops to UID 1000; allow traversal without directory listing.
      $DRY_RUN_CMD chmod 711 /data/${user}/gitea
      $DRY_RUN_CMD rm -f "${giteaDir}/compose.yaml" "${giteaDir}/Dockerfile" "${giteaDir}/pandoc-template.html"
      $DRY_RUN_CMD install -m 644 ${./gitea/compose.yaml} "${giteaDir}/compose.yaml"
      $DRY_RUN_CMD install -m 644 ${./gitea/Dockerfile} "${giteaDir}/Dockerfile"
      $DRY_RUN_CMD install -m 644 ${./gitea/pandoc-template.html} "${giteaDir}/pandoc-template.html"
    '';

  systemd.user.services.gitea = {
    Unit = {
      Description = "Private Gitea server with Pandoc DOCX rendering";
      After = [ "agenix.service" "network-online.target" ];
      Wants = [ "network-online.target" ];
      Requires = [ "agenix.service" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = giteaDir;
      ExecStartPre = waitForTailscale;
      ExecStart = "${docker} compose up --build --detach --remove-orphans";
      ExecStop = "${docker} compose down";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 600;
      TimeoutStopSec = 120;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.gitea-tailscale-serve = {
    Unit = {
      Description = "Tailscale HTTPS ingress for Gitea";
      After = [ "gitea.service" ];
      Requires = [ "gitea.service" ];
      StartLimitIntervalSec = 300;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = serveGitea;
      ExecStop = "${tailscale} serve --yes --https=443 off";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 150;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.croc-relay = {
    Unit = {
      Description = "croc self-hosted relay (Tailscale-only bind)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${pkgs.croc}/bin/croc relay --host 100.70.33.29";
      Restart = "always";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
