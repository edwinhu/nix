{ pkgs, ... }:
let
  # Reconnects paired Nintendo Joy-Cons over Bluetooth.
  # Joy-Cons don't reliably re-establish their HID link after macOS sleep —
  # they show as paired-but-disconnected and require a manual forget+repair
  # unless something forces a reconnect. This script enumerates paired
  # Joy-Cons by name and asks blueutil to reconnect any that are dropped.
  #
  # Set JOYCON_BOUNCE_BT=1 to power-cycle Bluetooth before reconnecting
  # (helps when macOS holds a stale pairing state on wake).
  joyconReconnect = pkgs.writeShellApplication {
    name = "joycon-reconnect";
    runtimeInputs = with pkgs; [ blueutil jq coreutils ];
    text = ''
      log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

      # Give Bluetooth a moment to come up after wake.
      sleep 2

      if [[ "''${JOYCON_BOUNCE_BT:-0}" == "1" ]]; then
        log "bouncing bluetooth"
        blueutil --power 0 || true
        sleep 1
        blueutil --power 1 || true
        sleep 2
      fi

      # Enumerate paired Joy-Cons (matches "Joy-Con (L)", "Joy-Con (R)",
      # or any name containing "Joy-Con", case-insensitive).
      addrs="$(blueutil --paired --format json \
        | jq -r '.[] | select(.name | test("Joy-Con"; "i")) | .address')"

      if [[ -z "$addrs" ]]; then
        log "no paired Joy-Cons found"
        exit 0
      fi

      while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        if [[ "$(blueutil --is-connected "$addr" 2>/dev/null)" == "1" ]]; then
          log "$addr already connected"
          continue
        fi
        log "connecting $addr"
        # blueutil --connect blocks ~15s and may report failure even when
        # the link succeeds asynchronously. Ignore its exit code; the only
        # reliable signal is --is-connected afterwards.
        blueutil --connect "$addr" >/dev/null 2>&1 || true
        connected=0
        for _ in 1 2 3 4 5; do
          if [[ "$(blueutil --is-connected "$addr" 2>/dev/null)" == "1" ]]; then
            connected=1
            break
          fi
          sleep 1
        done
        if [[ "$connected" == "1" ]]; then
          log "$addr connected"
        else
          log "$addr still disconnected — press a button to wake the controller"
        fi
      done <<< "$addrs"
    '';
  };
in
{
  # blueutil + sleepwatcher available system-wide (and on PATH for ad-hoc use)
  environment.systemPackages = with pkgs; [ blueutil sleepwatcher ];

  # sleepwatcher runs as a user agent and executes joycon-reconnect on wake.
  # -w runs the script on wakeup; KeepAlive restarts sleepwatcher if it exits.
  launchd.user.agents.joycon-reconnect = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.sleepwatcher}/bin/sleepwatcher"
        "-V"
        "-w" "${joyconReconnect}/bin/joycon-reconnect"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/Users/vwh7mb/Library/Logs/joycon-reconnect.log";
      StandardErrorPath = "/Users/vwh7mb/Library/Logs/joycon-reconnect.log";
    };
  };
}
