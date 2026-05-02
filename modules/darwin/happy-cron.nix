{ config, pkgs, user, ... }:
let
  scriptsDir = "/Users/${user}/.happy/scripts";
  logsDir = "/Users/${user}/.happy/logs";
  commonEnv = {
    PATH = "/Users/${user}/.local/bin:/Users/${user}/.bun/bin:/Users/${user}/.pixi/bin:/Users/${user}/.nix-profile/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    HOME = "/Users/${user}";
  };

  # Helper to build a calendar-triggered launchd agent
  mkScheduledAgent = name: { hour, minute ? 0 }: {
    serviceConfig = {
      ProgramArguments = [ "/bin/bash" "${scriptsDir}/${name}.sh" ];
      EnvironmentVariables = commonEnv;
      StartCalendarInterval = { Hour = hour; Minute = minute; };
      ProcessType = "Background";
      StandardOutPath = "${logsDir}/${name}.out.log";
      StandardErrorPath = "${logsDir}/${name}.err.log";
      WorkingDirectory = "/Users/${user}";
    };
  };
in
{
  # Scheduled Happy agents — replaces crontab entries.
  # launchd runs missed jobs on wake (unlike cron which silently skips them).
  launchd.user.agents = {
    # Ensure a persistent ~/ session exists for cron scripts to target.
    # Runs at login and every 15 minutes to respawn if the session dies.
    happy-home-session = {
      serviceConfig = {
        ProgramArguments = [ "/bin/bash" "${scriptsDir}/ensure-home-session.sh" ];
        EnvironmentVariables = commonEnv;
        RunAtLoad = true;
        StartInterval = 900;
        ProcessType = "Background";
        StandardOutPath = "${logsDir}/ensure-home-session.out.log";
        StandardErrorPath = "${logsDir}/ensure-home-session.err.log";
        WorkingDirectory = "/Users/${user}";
      };
    };

    happy-morning-briefing = mkScheduledAgent "morning-briefing" { hour = 8; minute = 45; };
    happy-morning-planning = mkScheduledAgent "morning-planning" { hour = 10; minute = 0; };
    happy-nightly-wrapup   = mkScheduledAgent "nightly-wrapup"   { hour = 23; minute = 0; };
    happy-vault-compile    = mkScheduledAgent "vault-compile"    { hour = 3;  minute = 0; };
  };
}
