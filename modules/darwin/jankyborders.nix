{ pkgs, ... }:
let
  bordersStart = pkgs.writeShellApplication {
    name = "borders-start";
    runtimeInputs = [ pkgs.jankyborders ];
    text = ''
      THEME_COLORS="''${HOME}/.config/themes/current/colors.sh"
      ACTIVE=0xffe1e3e4
      INACTIVE=0xff494d64
      if [ -f "$THEME_COLORS" ]; then
        # shellcheck disable=SC1090
        source "$THEME_COLORS"
        ACTIVE="''${THEME_BORDER_ACTIVE:-$ACTIVE}"
        INACTIVE="''${THEME_BORDER_INACTIVE:-$INACTIVE}"
      fi
      exec borders active_color="$ACTIVE" inactive_color="$INACTIVE" width=8.0
    '';
  };
in
{
  launchd.user.agents.jankyborders = {
    serviceConfig = {
      ProgramArguments = [ "${bordersStart}/bin/borders-start" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Interactive";
      StandardOutPath = "/Users/vwh7mb/Library/Logs/jankyborders.log";
      StandardErrorPath = "/Users/vwh7mb/Library/Logs/jankyborders.log";
    };
  };
}
