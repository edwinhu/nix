# Cross-platform reader services: chrome-cdp + readwise-reader-tools (+ its
# cloudflared tunnel).
#
# ONE module, TWO backends. On Linux (home-manager on omarchy/alarm) it emits
# systemd *user* services + a timer (and, where readwise is enabled, the
# cloudflared tunnel that fronts the webhook + its agenix creds); on macOS
# (home-manager inside nix-darwin) it emits launchd *agents*. The service bodies are thin wrappers around the
# platform-aware CLIs/scripts that already live in the repos
# (~/projects/chrome-cdp, ~/projects/readwise-reader-tools): those handle the
# chromium-vs-Chrome binary, headless mode, XDG isolation, and the agenix
# secrets dir, so this module only has to invoke them per-platform.
#
# CRITICAL EVAL PATTERN: `systemd.*` exists only on Linux home-manager and
# `launchd.*` only on Darwin. Referencing the missing one — even under
# `lib.mkIf` — is an "option does not exist" error. So we gate at the ATTRSET
# level with `lib.optionalAttrs`: the whole `systemd`/`launchd` key is absent on
# the wrong platform, so its option is never touched there.
{ config, pkgs, lib, userInfo, nix-secrets, ... }:

# Platform gate uses `userInfo.system` (a plain string from specialArgs), NOT
# `pkgs.stdenv.is*`. Whether the top-level `systemd`/`launchd` key exists decides
# the module's freeform type; if that decision reads `pkgs`, the module system
# must resolve `_module.args.pkgs` (→ config → options) before it can compute the
# option set → infinite recursion. `userInfo.system` is available in the module
# fixpoint without forcing config, so it breaks that cycle.
let
  isLinux = lib.hasSuffix "linux" userInfo.system;
  isDarwin = lib.hasSuffix "darwin" userInfo.system;

  # WHICH services run is decided per-computer in the host config files, via the
  # options.readerServices toggles defined below — NOT hardcoded here. omarchy
  # sets enableReadwise + enableChromeCdp; the Mac sets enableChromeCdp only
  # (readwise webhook+sweep run on the always-on primary ONLY, else a second
  # sweep double-saves and its webhook fights the Cloudflare tunnel). Defaults
  # are false, so a host that imports this module but toggles nothing gets nothing.
  cfg = config.readerServices;

  home = config.home.homeDirectory;

  # ---- shared constants (mirror the local systemd units + the repo plists) ----
  cdpPort = "9250";
  cdpUrl = "http://localhost:${cdpPort}";
  webhookPort = "8000";
  sweepInterval = 3 * 60 * 60; # 3h == 10800s (matches launchd StartInterval)

  chromeCdpBin = "${home}/.local/bin/chrome-cdp"; # symlink -> repo bin/chrome-cdp
  readwiseDir = "${home}/projects/readwise-reader-tools";
  sweepScript = "${readwiseDir}/scripts/sweep.sh";
  envFile = "${readwiseDir}/.env"; # 0600, agenix-sourced, gitignored — never committed
  logDir = "${home}/.local/log";
  readwiseLogDir = "${readwiseDir}/logs";

  # chrome-cdp watchdog (Linux). The service's Restart=on-failure only catches
  # process EXIT, not "process alive but CDP socket wedged" (chromium came up
  # without --remote-debugging-port, or the tab host hung). This probes the HTTP
  # endpoint and restarts the service when it can't be reached — the Linux
  # analogue of the repo's launchd-only bin/chrome-cdp-watchdog. `systemctl`
  # resolves from /usr/bin via the unit's PATH (linuxPath).
  cdpWatchdogScript = pkgs.writeShellScript "chrome-cdp-watchdog" ''
    set -u
    # No desktop session -> chrome-cdp is intentionally down; don't fight it.
    systemctl --user is-active --quiet graphical-session.target || exit 0
    if ${pkgs.curl}/bin/curl -sf --max-time 5 "${cdpUrl}/json/version" >/dev/null 2>&1; then
      exit 0  # healthy — silent, so the log stays quiet
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) chrome-cdp-watchdog: CDP probe failed (${cdpUrl}/json/version); restarting chrome-cdp.service" >&2
    systemctl --user restart chrome-cdp.service || true
  '';

  # pixi (nix-profile) + user local bin + system dirs. curl/python3 live in /usr/bin.
  linuxPath = "${home}/.nix-profile/bin:${home}/.local/bin:/usr/local/bin:/usr/bin:/bin";
  darwinPath = "${home}/.nix-profile/bin:${home}/.pixi/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

  pixiBin = "${home}/.nix-profile/bin/pixi";
  # webhook server: uvicorn under pixi, bound to all interfaces on :8000.
  uvicornArgs = [ "run" "uvicorn" "src.webhook:app" "--host" "0.0.0.0" "--port" webhookPort ];

  # ---- cloudflared (Cloudflare Tunnel fronting the webhook) ----
  # The named tunnel + its DNS route (webhook.eddyhu.com) already exist in the
  # Cloudflare dashboard; this host just runs it. Creds JSON is agenix-decrypted
  # to credsPath; the config is generated into the nix store so nothing loose
  # lives in ~/.cloudflared any more.
  tunnelId = "292cc54f-6568-47ed-a605-a428d892dcb1";
  cfCredsPath = "${home}/.cloudflared/${tunnelId}.json";
  cfCertPath = "${home}/.cloudflared/cert.pem";
  cloudflaredBin = "${pkgs.cloudflared}/bin/cloudflared";
  cloudflaredConfig = pkgs.writeText "cloudflared-config.yml" ''
    tunnel: ${tunnelId}
    credentials-file: ${cfCredsPath}

    ingress:
      - hostname: webhook.eddyhu.com
        service: http://localhost:${webhookPort}
      - service: http_status:404
  '';
in
{
  # Per-computer toggles — SET THESE IN THE HOST CONFIG FILES, not here.
  #   omarchy:     readerServices = { enableChromeCdp = true; enableReadwise = true; };
  #   macbook-pro: readerServices.enableChromeCdp = true;   # readwise off (primary = omarchy)
  #   alarm:       (leave both false — the module is imported but emits nothing)
  options.readerServices = {
    enableChromeCdp = lib.mkEnableOption
      "the chrome-cdp authenticated headless browser daemon (CDP on :9250)";
    enableReadwise = lib.mkEnableOption
      "the readwise-reader-tools webhook + sweep (enable on exactly ONE always-on host — a second sweep double-saves)";
  };

  config = lib.mkMerge [

  # ===================== Linux: systemd user services =====================
  (lib.optionalAttrs isLinux {
    systemd.user.services.chrome-cdp = lib.mkIf cfg.enableChromeCdp {
      Unit = {
        Description = "chrome-cdp — persistent headless chromium bound to CDP port ${cdpPort}";
        # uwsm exports WAYLAND_DISPLAY / DBUS into graphical-session.target user
        # services, which chromium needs even headless.
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        WorkingDirectory = "%h";
        # Force the dedicated port explicitly: the omarchy login session exports
        # CDP_PORT=9222 (the Superhuman/Morgen browser); without this the daemon
        # would inherit 9222 and collide with that instance.
        Environment = [ "CDP_PORT=${cdpPort}" ];
        ExecStart = "${chromeCdpBin} daemon";
        Restart = "on-failure";
        RestartSec = 5;
        StartLimitIntervalSec = 120;
        StartLimitBurst = 5;
        Nice = 5;
        StandardOutput = "append:${logDir}/chrome-cdp.log";
        StandardError = "append:${logDir}/chrome-cdp.err";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Detects a wedged (alive-but-unresponsive) CDP port and restarts the daemon;
    # see cdpWatchdogScript above. Timer fires every 2min (mirrors the macOS
    # com.chrome-cdp-watchdog StartInterval=120).
    systemd.user.services.chrome-cdp-watchdog = lib.mkIf cfg.enableChromeCdp {
      Unit = {
        Description = "chrome-cdp watchdog — restart chrome-cdp.service if CDP :${cdpPort} is unresponsive";
        After = [ "chrome-cdp.service" ];
      };
      Service = {
        Type = "oneshot";
        Environment = [ "PATH=${linuxPath}" ];
        ExecStart = "${cdpWatchdogScript}";
        Nice = 10;
        StandardOutput = "append:${logDir}/chrome-cdp-watchdog.log";
        StandardError = "append:${logDir}/chrome-cdp-watchdog.log";
      };
    };

    systemd.user.timers.chrome-cdp-watchdog = lib.mkIf cfg.enableChromeCdp {
      Unit.Description = "chrome-cdp watchdog timer (probe CDP :${cdpPort} every 2min)";
      Timer = {
        # First probe ~2min after login (chrome-cdp needs time to come up), then
        # every 2min thereafter.
        OnStartupSec = "2min";
        OnUnitActiveSec = "2min";
        Persistent = false;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    systemd.user.services.readwise-webhook = lib.mkIf cfg.enableReadwise {
      Unit = {
        Description = "readwise-reader-tools webhook server (uvicorn on :${webhookPort})";
        # Needs the chrome-cdp browser (:${cdpPort}) to fetch paywalled articles.
        Requires = [ "chrome-cdp.service" ];
        After = [ "chrome-cdp.service" "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        WorkingDirectory = readwiseDir;
        Environment = [ "PATH=${linuxPath}" "HOME=${home}" ];
        # Tokens + CDP config come from the 0600 .env (agenix-sourced, gitignored).
        EnvironmentFile = envFile;
        ExecStart = "${pixiBin} ${lib.concatStringsSep " " uvicornArgs}";
        Restart = "on-failure";
        RestartSec = 10;
        StartLimitIntervalSec = 120;
        StartLimitBurst = 5;
        Nice = 5;
        StandardOutput = "append:${readwiseLogDir}/webhook.log";
        StandardError = "append:${readwiseLogDir}/webhook.err";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.readwise-sweep = lib.mkIf cfg.enableReadwise {
      Unit = {
        Description = "readwise-reader-tools sweep — resave articles that missed the webhook";
        # Needs the chrome-cdp browser (:${cdpPort}). sweep.sh no-ops if CDP is down.
        Requires = [ "chrome-cdp.service" ];
        After = [ "chrome-cdp.service" "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        WorkingDirectory = readwiseDir;
        Environment = [ "PATH=${linuxPath}" "HOME=${home}" ];
        EnvironmentFile = envFile;
        ExecStart = sweepScript;
        Nice = 10;
        StandardOutput = "append:${readwiseLogDir}/sweep.log";
        StandardError = "append:${readwiseLogDir}/sweep.log";
      };
    };

    systemd.user.timers.readwise-sweep = lib.mkIf cfg.enableReadwise {
      Unit.Description = "readwise-reader-tools sweep timer (every 3h + shortly after login)";
      Timer = {
        # Mirror the launchd plist: StartInterval=10800 (3h) + RunAtLoad.
        # OnStartupSec fires ~2min after the user manager starts (login/boot);
        # OnUnitActiveSec repeats every 3h thereafter.
        OnStartupSec = "2min";
        OnUnitActiveSec = "3h";
        Persistent = false;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # cloudflared CLI (management + the version the service runs), from nixpkgs
    # rather than the pacman /usr/bin/cloudflared — shadows it via PATH order.
    home.packages = lib.mkIf cfg.enableReadwise [ pkgs.cloudflared ];

    # Tunnel creds + account cert, agenix-decrypted into ~/.cloudflared as real
    # 0600 files (symlink=false so cloudflared/StrictModes accept them and they
    # persist across reboots). agenix mkdir -p's ~/.cloudflared itself.
    age.secrets.cloudflared-webhook-creds = lib.mkIf cfg.enableReadwise {
      file = "${nix-secrets}/cloudflared-webhook-creds.age";
      path = cfCredsPath;
      mode = "600";
      symlink = false;
    };
    age.secrets.cloudflared-cert = lib.mkIf cfg.enableReadwise {
      file = "${nix-secrets}/cloudflared-cert.age";
      path = cfCertPath;
      mode = "600";
      symlink = false;
    };

    systemd.user.services.cloudflared = lib.mkIf cfg.enableReadwise {
      Unit = {
        Description = "cloudflared tunnel (webhook.eddyhu.com -> readwise webhook :${webhookPort})";
        # Lifecycle with the webhook it fronts; needs the network up first.
        After = [ "network-online.target" "readwise-webhook.service" "graphical-session.target" ];
        Wants = [ "network-online.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        # Config is a store file (tunnel id + creds path + ingress); no loose
        # ~/.cloudflared/config.yml. --no-autoupdate: nix owns the binary version.
        ExecStart = "${cloudflaredBin} tunnel --no-autoupdate --config ${cloudflaredConfig} run";
        Restart = "on-failure";
        RestartSec = 5;
        StartLimitIntervalSec = 120;
        StartLimitBurst = 5;
        StandardOutput = "append:${logDir}/cloudflared.log";
        StandardError = "append:${logDir}/cloudflared.err";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  })

  # ===================== macOS: launchd user agents =====================
  (lib.optionalAttrs isDarwin {
    # Mirrors chrome-cdp/LaunchAgents/com.chrome-cdp.plist.
    launchd.agents.chrome-cdp = lib.mkIf cfg.enableChromeCdp {
      enable = true;
      config = {
        Label = "com.chrome-cdp";
        ProgramArguments = [ chromeCdpBin "daemon" ];
        WorkingDirectory = home;
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        ThrottleInterval = 30;
        StandardOutPath = "${logDir}/chrome-cdp.log";
        StandardErrorPath = "${logDir}/chrome-cdp.err";
        EnvironmentVariables = {
          PATH = darwinPath;
          HOME = home;
          CDP_PORT = cdpPort;
        };
        Nice = 5;
      };
    };

    # Mirrors readwise-reader-tools/com.user.readwise-webhook.plist. Tokens are
    # NOT baked here — webhook_server.sh sources the agenix dir + .env itself.
    launchd.agents.readwise-webhook = lib.mkIf cfg.enableReadwise {
      enable = true;
      config = {
        Label = "com.user.readwise-webhook";
        ProgramArguments = [ pixiBin ] ++ uvicornArgs;
        WorkingDirectory = readwiseDir;
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        ThrottleInterval = 10;
        StandardOutPath = "${readwiseLogDir}/webhook.log";
        StandardErrorPath = "${readwiseLogDir}/webhook.err";
        EnvironmentVariables = {
          PATH = darwinPath;
          HOME = home;
          CDP_PORT = cdpPort;
          CDP_URL = cdpUrl;
        };
        ProcessType = "Interactive";
        Nice = 5;
      };
    };

    # Mirrors readwise-reader-tools/com.readwise.sweep.plist (StartInterval=10800).
    launchd.agents.readwise-sweep = lib.mkIf cfg.enableReadwise {
      enable = true;
      config = {
        Label = "com.readwise.sweep";
        ProgramArguments = [ sweepScript ];
        WorkingDirectory = readwiseDir;
        StartInterval = sweepInterval;
        RunAtLoad = true;
        StandardOutPath = "${readwiseLogDir}/sweep.log";
        StandardErrorPath = "${readwiseLogDir}/sweep.log";
        EnvironmentVariables = {
          PATH = darwinPath;
          HOME = home;
          CDP_PORT = cdpPort;
          CDP_URL = cdpUrl;
        };
        Nice = 10;
      };
    };
  })
  ];
}
