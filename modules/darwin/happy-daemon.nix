{ config, pkgs, user, ... }:
{
  # Auto-start the Happy daemon at login.
  # The daemon spawns/manages remote-controlled Claude sessions.
  # `happy daemon start-sync` runs in the foreground so launchd manages the lifecycle.
  # Path points at the from-source build in ~/projects/happy (managed by
  # scripts/setup-ai-tools.sh's install_happy). Rebuilding via
  # `pnpm --filter happy build` is a no-op for launchd — the dist file is
  # overwritten in place, so KeepAlive picks up the new code on next restart.
  launchd.user.agents.happy-daemon = {
    serviceConfig = {
      ProgramArguments = [
        "/Users/${user}/.nix-profile/bin/node"
        "--no-warnings"
        "--no-deprecation"
        "/Users/${user}/projects/happy/packages/happy-cli/dist/index.mjs"
        "daemon"
        "start-sync"
      ];
      EnvironmentVariables = {
        PATH = "/Users/${user}/.nix-profile/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        HOME = "/Users/${user}";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/Users/${user}/.happy/logs/launchd-daemon.out.log";
      StandardErrorPath = "/Users/${user}/.happy/logs/launchd-daemon.err.log";
      WorkingDirectory = "/Users/${user}";
    };
  };
}
