{ pkgs, ... }:
let
  # Auto-switch from a weak Wi-Fi network to a stronger preferred one.
  # Polls current SSID via networksetup; on match, compares RSSI from the
  # shared Wi-Fi scan cache (system_profiler — no sudo, no forced scan).
  wifiAutoswitch = pkgs.writeShellApplication {
    name = "wifi-autoswitch";
    runtimeInputs = with pkgs; [ coreutils gawk gnused ];
    text = ''
      IFACE="''${WIFI_AUTOSWITCH_IFACE:-en0}"
      WEAK_SSID="''${WIFI_AUTOSWITCH_WEAK:-eduroam}"
      STRONG_SSID="''${WIFI_AUTOSWITCH_STRONG:-ivorytower}"
      THRESHOLD="''${WIFI_AUTOSWITCH_THRESHOLD:--70}"
      MARGIN="''${WIFI_AUTOSWITCH_MARGIN:-10}"

      log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

      current_ssid() {
        /usr/sbin/networksetup -getairportnetwork "$IFACE" 2>/dev/null \
          | sed -n 's/^Current Wi-Fi Network: //p'
      }

      get_rssi() {
        local target="$1" sp="$2"
        awk -v t="$target" '
          $0 ~ "^[[:space:]]+" t ":[[:space:]]*$" { waiting=1; next }
          waiting && /Signal \/ Noise:/ {
            match($0, /-?[0-9]+/)
            print substr($0, RSTART, RLENGTH)
            exit
          }
        ' <<< "$sp"
      }

      cur="$(current_ssid || true)"
      if [[ "$cur" != "$WEAK_SSID" ]]; then
        exit 0
      fi

      sp="$(/usr/sbin/system_profiler SPAirPortDataType 2>/dev/null || true)"
      cur_rssi="$(get_rssi "$WEAK_SSID" "$sp" || true)"
      strong_rssi="$(get_rssi "$STRONG_SSID" "$sp" || true)"

      if [[ -z "$cur_rssi" ]]; then
        exit 0
      fi

      if (( cur_rssi >= THRESHOLD )); then
        exit 0
      fi

      if [[ -z "$strong_rssi" ]]; then
        log "weak $WEAK_SSID ($cur_rssi dBm) but $STRONG_SSID not visible"
        exit 0
      fi

      diff=$(( strong_rssi - cur_rssi ))
      if (( diff < MARGIN )); then
        log "weak $WEAK_SSID ($cur_rssi dBm) vs $STRONG_SSID ($strong_rssi dBm) — margin $diff < $MARGIN"
        exit 0
      fi

      log "switching: $WEAK_SSID ($cur_rssi dBm) -> $STRONG_SSID ($strong_rssi dBm)"
      if out="$(/usr/sbin/networksetup -setairportnetwork "$IFACE" "$STRONG_SSID" 2>&1)"; then
        log "switched: ''${out:-ok}"
      else
        log "switch failed: $out"
      fi
    '';
  };
in
{
  launchd.user.agents.wifi-autoswitch = {
    serviceConfig = {
      ProgramArguments = [ "${wifiAutoswitch}/bin/wifi-autoswitch" ];
      StartInterval = 180;
      RunAtLoad = true;
      ProcessType = "Background";
      LowPriorityIO = true;
      Nice = 10;
      StandardOutPath = "/Users/vwh7mb/Library/Logs/wifi-autoswitch.log";
      StandardErrorPath = "/Users/vwh7mb/Library/Logs/wifi-autoswitch.log";
    };
  };
}
