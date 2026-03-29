# the-companion - Web UI for Claude Code agents
# Runs as launchd service, exposed on tailnet via tailscale serve
{ pkgs, lib, user, ... }:

let
  tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  port = 3456;
  companionUrl = "http://localhost:${toString port}";
  bundleId = "com.clawd.companion";

  containers-json = "/Users/${user}/.companion/containers.json";

  # Clawd.app Info.plist for Chrome app_mode_loader
  clawd-plist = pkgs.writeText "clawd-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key><string>en</string>
      <key>CFBundleExecutable</key><string>app_mode_loader</string>
      <key>CFBundleIconFile</key><string>app.icns</string>
      <key>CFBundleIdentifier</key><string>${bundleId}</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundleName</key><string>Clawd</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>1.0</string>
      <key>CFBundleSignature</key><string>????</string>
      <key>CrAppModeIsAdhocSigned</key><true/>
      <key>CrAppModeShortcutID</key><string>clawd-companion</string>
      <key>CrAppModeShortcutName</key><string>Clawd</string>
      <key>CrAppModeShortcutURL</key><string>${companionUrl}</string>
      <key>CrAppModeUserDataDir</key><string>/Users/${user}/Library/Application Support/Google/Chrome/Default</string>
      <key>CrBundleIdentifier</key><string>com.google.Chrome</string>
      <key>LSEnvironment</key>
      <dict>
        <key>MallocNanoZone</key><string>0</string>
      </dict>
      <key>NSAppleScriptEnabled</key><true/>
      <key>NSHighResolutionCapable</key><true/>
      <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    </dict>
    </plist>
  '';

  # Script to prune dead Docker containers from containers.json on startup
  prune-containers = pkgs.writers.writePython3 "prune-containers" {
    flakeIgnore = [ "E501" ];
  } ''
      import json
      import subprocess
      import sys

      path = "${containers-json}"
      try:
          with open(path) as f:
              entries = json.load(f)
          if not entries:
              sys.exit(0)
          alive = []
          for e in entries:
              cid = e.get("info", {}).get("containerId", "")
              if cid:
                  rc = subprocess.call(
                      ["docker", "inspect", cid],
                      stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL,
                  )
                  if rc == 0:
                      alive.append(e)
                  else:
                      name = e.get("info", {}).get("name", cid[:12])
                      print(f"[preflight] pruned dead container {name}", file=sys.stderr)
              else:
                  alive.append(e)
          if len(alive) != len(entries):
              with open(path, "w") as f:
                  json.dump(alive, f, indent=2)
      except Exception as ex:
          print(f"[preflight] container prune skipped: {ex}", file=sys.stderr)
  '';

  # Watchdog: health check, crash-loop detection, log rotation, session cap
  companion-watchdog = pkgs.writeShellScript "the-companion-watchdog" ''
    LOG="/tmp/the-companion.log"
    WATCHDOG_LOG="/tmp/the-companion-watchdog.log"
    API="http://localhost:${toString port}"
    MAX_LOG_LINES=50000
    MAX_SESSIONS=30
    CRASH_WINDOW=300      # 5 minutes
    CRASH_THRESHOLD=5
    STARTUP_GRACE=45      # seconds to wait after process start before health-checking
    FAIL_THRESHOLD=3      # consecutive failures before restarting

    STATE_DIR="/tmp/the-companion-watchdog-state"
    mkdir -p "$STATE_DIR"
    BACKOFF_FILE="$STATE_DIR/backoff"
    FAIL_COUNT_FILE="$STATE_DIR/fail-count"
    RESTART_COUNT_FILE="$STATE_DIR/restart-count"
    RESTART_WINDOW_FILE="$STATE_DIR/restart-window-start"
    LAST_HEALTHY_FILE="$STATE_DIR/last-healthy"

    LAUNCHD_SVC="gui/$(id -u)/org.nixos.the-companion"

    ts() { date "+%Y-%m-%d %H:%M:%S"; }
    NOW=$(date +%s)

    # ── Log rotation ──
    if [ -f "$LOG" ]; then
      LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
      if [ "$LINES" -gt "$MAX_LOG_LINES" ]; then
        tail -n 10000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        echo "$(ts) [watchdog] rotated log ($LINES -> 10000 lines)" >> "$WATCHDOG_LOG"
      fi
    fi

    # ── Startup grace period ──
    # Don't health-check if the companion process started recently
    PID=$(launchctl print "$LAUNCHD_SVC" 2>/dev/null | grep '^\s*pid =' | awk '{print $3}')
    if [ -n "$PID" ] && [ "$PID" != "0" ]; then
      # Get process start time (seconds since epoch)
      PROC_START=$(ps -o lstart= -p "$PID" 2>/dev/null | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null || echo "0")
      UPTIME=$((NOW - PROC_START))
      if [ "$UPTIME" -lt "$STARTUP_GRACE" ] && [ "$UPTIME" -ge 0 ]; then
        exit 0
      fi
    fi

    # ── Crash-loop detection (counts watchdog-initiated restarts too) ──
    RESTART_COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo 0)
    WINDOW_START=$(cat "$RESTART_WINDOW_FILE" 2>/dev/null || echo "$NOW")
    WINDOW_AGE=$((NOW - WINDOW_START))

    if [ "$WINDOW_AGE" -gt "$CRASH_WINDOW" ]; then
      echo "0" > "$RESTART_COUNT_FILE"
      echo "$NOW" > "$RESTART_WINDOW_FILE"
      rm -f "$BACKOFF_FILE"
      RESTART_COUNT=0
    elif [ "$RESTART_COUNT" -ge "$CRASH_THRESHOLD" ]; then
      if [ ! -f "$BACKOFF_FILE" ]; then
        echo "$(ts) [watchdog] crash-loop: $RESTART_COUNT restarts in ''${WINDOW_AGE}s — backing off 120s" >> "$WATCHDOG_LOG"
        touch "$BACKOFF_FILE"
        exit 0
      else
        # Already backing off — skip until window resets
        exit 0
      fi
    fi

    # ── Health check with consecutive failure tracking ──
    HEALTH=$(curl -s --connect-timeout 3 --max-time 8 "$API/health" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"ok":true'; then
      # Healthy — reset failure counter, record timestamp
      echo "0" > "$FAIL_COUNT_FILE"
      echo "$NOW" > "$LAST_HEALTHY_FILE"

      # Check session count
      SESSION_COUNT=$(echo "$HEALTH" | grep -oE '"sessions":[0-9]+' | grep -oE '[0-9]+')
      SESSION_COUNT=''${SESSION_COUNT:-0}
      if [ "$SESSION_COUNT" -gt "$MAX_SESSIONS" ]; then
        echo "$(ts) [watchdog] $SESSION_COUNT sessions exceeds cap ($MAX_SESSIONS), running cleanup" >> "$WATCHDOG_LOG"
        SESSIONS=$(curl -s --max-time 10 "$API/api/sessions" 2>/dev/null || echo "[]")
        echo "$SESSIONS" | ${pkgs.python3}/bin/python3 -c "
    import json, sys
    try:
        sessions = json.load(sys.stdin)
        stale = [s for s in sessions if s.get('state') in ('exited', 'stopped', 'error')]
        for s in stale[:20]:
            print(s['sessionId'])
    except:
        pass
    " | while read -r sid; do
          curl -s -X DELETE "$API/api/sessions/$sid" >/dev/null 2>&1 || true
        done
      fi
    else
      # Unhealthy — increment failure counter
      FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
      FAILS=$((FAILS + 1))
      echo "$FAILS" > "$FAIL_COUNT_FILE"

      LAST_HEALTHY=$(cat "$LAST_HEALTHY_FILE" 2>/dev/null || echo "unknown")
      if [ "$LAST_HEALTHY" != "unknown" ]; then
        DOWN_FOR=$((NOW - LAST_HEALTHY))
        DOWN_MSG=" (down ''${DOWN_FOR}s)"
      else
        DOWN_MSG=""
      fi

      if [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
        if launchctl print "$LAUNCHD_SVC" 2>/dev/null | grep -q 'state = running'; then
          echo "$(ts) [watchdog] $FAILS consecutive health failures''${DOWN_MSG}, restarting" >> "$WATCHDOG_LOG"
          launchctl kill SIGTERM "$LAUNCHD_SVC" 2>/dev/null || true
          sleep 3
          launchctl kickstart "$LAUNCHD_SVC" 2>/dev/null || true
          # Track this restart for crash-loop detection
          RESTART_COUNT=$((RESTART_COUNT + 1))
          echo "$RESTART_COUNT" > "$RESTART_COUNT_FILE"
          echo "0" > "$FAIL_COUNT_FILE"
        else
          echo "$(ts) [watchdog] companion not running, kickstarting" >> "$WATCHDOG_LOG"
          launchctl kickstart "$LAUNCHD_SVC" 2>/dev/null || true
          RESTART_COUNT=$((RESTART_COUNT + 1))
          echo "$RESTART_COUNT" > "$RESTART_COUNT_FILE"
          echo "0" > "$FAIL_COUNT_FILE"
        fi
      fi
    fi
  '';

  # Wrapper script that reads agenix _FILE secrets into env vars before exec'ing
  companion-wrapper = pkgs.writeShellScript "the-companion-wrapper" ''
    # ── Pre-flight: wait for claude binary (avoids crash-loop during CC updates) ──
    CLAUDE="/Users/${user}/.local/bin/claude"
    TRIES=0
    while [ ! -x "$CLAUDE" ]; do
      TRIES=$((TRIES + 1))
      if [ "$TRIES" -ge 30 ]; then
        echo "[preflight] claude binary missing after 30s, starting anyway" >&2
        break
      fi
      [ "$TRIES" -eq 1 ] && echo "[preflight] waiting for $CLAUDE (update in progress?)..." >&2
      sleep 1
    done

    # ── Pre-flight: prune dead Docker containers from containers.json ──
    if [ -f "${containers-json}" ]; then
      ${prune-containers} 2>&1 || true
    fi

    # ── Read agenix secret files into environment variables ──
    for var in READWISE_TOKEN_FILE GEMINI_API_KEY_FILE GOOGLE_SEARCH_ENGINE_ID_FILE GOOGLE_SEARCH_API_KEY_FILE; do
      file="''${!var}"
      if [ -n "$file" ] && [ -f "$file" ]; then
        value="$(cat "$file")"
        case "$var" in
          READWISE_TOKEN_FILE)    export READWISE_TOKEN="$value" ;;
          GEMINI_API_KEY_FILE)    export GOOGLE_API_KEY="$value" ;;
          GOOGLE_SEARCH_ENGINE_ID_FILE) export GOOGLE_SEARCH_ENGINE_ID="$value" ;;
          GOOGLE_SEARCH_API_KEY_FILE)   export GOOGLE_SEARCH_API_KEY="$value" ;;
        esac
      fi
    done

    exec "/Users/${user}/.local/bin/the-companion" serve --port ${toString port}
  '';
in
{
  launchd.user.agents.the-companion = {
    serviceConfig = {
      ProgramArguments = [
        "${companion-wrapper}"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Background";
      AbandonProcessGroup = true;
      ThrottleInterval = 10;  # min seconds between restarts (prevents rapid crash-loop)
      StandardOutPath = "/tmp/the-companion.log";
      StandardErrorPath = "/tmp/the-companion.log";
      EnvironmentVariables = {
        PATH = "/Users/${user}/.local/bin:/Users/${user}/.nix-profile/bin:${pkgs.bun}/bin:${pkgs.nodejs}/bin:/usr/bin:/bin";
        HOME = "/Users/${user}";
        NODE_ENV = "production";
      };
    };
  };

  launchd.user.agents.the-companion-watchdog = {
    serviceConfig = {
      ProgramArguments = [
        "${companion-watchdog}"
      ];
      StartInterval = 60;  # run every 60 seconds
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion-watchdog.log";
      StandardErrorPath = "/tmp/the-companion-watchdog.log";
      EnvironmentVariables = {
        PATH = "/Users/${user}/.local/bin:/Users/${user}/.nix-profile/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin";
        HOME = "/Users/${user}";
      };
    };
  };

  # ── Clawd.app: standalone Chrome app wrapper ──
  # Uses Chrome's app_mode_loader with a custom bundle ID so AeroSpace
  # can target it separately and it gets its own Dock/Cmd+Tab presence.
  system.activationScripts.buildClawdApp.text = ''
    echo "Building Clawd.app..."
    CHROME_LOADER="/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/Current/Helpers/app_mode_loader"
    ICON_SRC="/Users/${user}/projects/companion/web/dist/icon-512.png"
    APP_DIR="/Applications/Clawd.app"

    if [ ! -f "$CHROME_LOADER" ]; then
      echo "  SKIP: Chrome not installed, cannot build Clawd.app"
    else
      rm -rf "$APP_DIR"
      mkdir -p "$APP_DIR/Contents/MacOS"
      mkdir -p "$APP_DIR/Contents/Resources"

      # Copy app_mode_loader binary
      cp "$CHROME_LOADER" "$APP_DIR/Contents/MacOS/app_mode_loader"
      chmod +x "$APP_DIR/Contents/MacOS/app_mode_loader"

      # Copy Info.plist
      cp ${clawd-plist} "$APP_DIR/Contents/Info.plist"

      # Convert PNG icon to icns
      if [ -f "$ICON_SRC" ]; then
        ICONSET=$(mktemp -d)/Clawd.iconset
        mkdir -p "$ICONSET"
        for sz in 16 32 128 256 512; do
          sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_''${sz}x''${sz}.png" >/dev/null 2>&1
          double=$((sz * 2))
          if [ $double -le 1024 ]; then
            sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_''${sz}x''${sz}@2x.png" >/dev/null 2>&1
          fi
        done
        iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/app.icns" 2>/dev/null
        rm -rf "$(dirname "$ICONSET")"
      fi

      # Ad-hoc sign and clear quarantine
      codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
      xattr -cr "$APP_DIR" 2>/dev/null || true

      echo "  Installed Clawd.app (bundle: ${bundleId})"
    fi
  '';

  launchd.user.agents.the-companion-tailserve = {
    serviceConfig = {
      ProgramArguments = [
        (toString (pkgs.writeShellScript "the-companion-tailserve" ''
          # Skip if tailscale serve is already active on this port
          if ${tailscale} serve status 2>/dev/null | grep -q ':${toString port}'; then
            echo "tailscale serve already active on port ${toString port}, skipping"
            exit 0
          fi
          exec ${tailscale} serve --bg ${toString port}
        ''))
      ];
      KeepAlive = false;
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/tmp/the-companion-tailserve.log";
      StandardErrorPath = "/tmp/the-companion-tailserve.log";
    };
  };
}
