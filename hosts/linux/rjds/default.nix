{ config, pkgs, lib, user, userInfo, ... }:

{
  imports = [
    ../../../modules/linux/home-manager.nix
    ../../../modules/shared/home-secrets.nix
  ];

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";
  };

  # Enable basic programs
  programs.home-manager.enable = true;

  # Self-hosted croc relay, bound to the Tailscale IP only (NOT the public
  # 128.122.x NYU IP). Lets machines transfer files P2P without croc's public
  # relay. Senders must use `croc send --no-local` so the sender's own local
  # relay does not race the rendezvous on this relay. Transfers are E2E
  # encrypted by the code phrase; access is gated by Tailscale (default relay
  # password is fine given the tailnet-only bind).
  systemd.user.services.croc-relay = {
    Unit = {
      Description = "croc self-hosted relay (Tailscale-only bind)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      # Retry until tailscaled has assigned 100.70.33.29 (bind fails until then).
      ExecStart = "${pkgs.croc}/bin/croc relay --host 100.70.33.29";
      Restart = "always";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };
}