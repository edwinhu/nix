{ pkgs, ... }:
{
  services.aerospace = {
    enable = true;
    package = pkgs.aerospace;
    settings = {
      after-login-command = [ ];
      after-startup-command = [ 
        "exec-and-forget ${pkgs.jankyborders}/bin/borders active_color=0xffe1e3e4 inactive_color=0xff494d64 width=5.0"
      ];

      key-mapping.preset = "qwerty";

      enable-normalization-flatten-containers = true;
      enable-normalization-opposite-orientation-for-nested-containers = true;

      accordion-padding = 14;

      default-root-container-layout = "tiles";
      default-root-container-orientation = "horizontal";

      exec-on-workspace-change = [
        "/bin/zsh"
        "-c"
        "${pkgs.sketchybar}/bin/sketchybar --trigger aerospace_workspace_changed FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE"
      ];

      on-focus-changed = [
        "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger front_app_switched"
      ];

      gaps = {
        outer = {
          top = 40;
          bottom = 10;
          left = 10;
          right = 10;
        };
        inner = {
          horizontal = 10;
          vertical = 10;
        };
      };

      workspace-to-monitor-force-assignment = {
      "0" = [ "secondary" ];
      "1" = [ "main" ];
      "2" = [ "main" ];
      "3" = [ "main" ];
      "4" = [ "main" ];
      "5" = [ "main" ];
      "C" = [ "main" ];
      "O" = [ "main" ];
      "N" = [ "main" ];
      "E" = [ "main" ];
      "P" = [ "main" ];
      "T" = [ "main" ];
      "W" = [ "main" ];
    };

      on-window-detected = [
        ####### Floating Windows #######
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.apple.finder";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.binarynights.ForkLift";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.bitwarden.desktop";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.automattic.beeper.desktop";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "us.zoom.xos";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.granola.app";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.superduper.superwhisper";
          };
          run = [
            "layout floating" "move-node-to-workspace 0"
          ];
        }
        ####### App-specific Spaces #######
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.electron.logseq";
          };
          run = [
            "move-node-to-workspace N"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "md.obsidian";
          };
          run = [
            "move-node-to-workspace O"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            window-title-regex-substring = "^Morgen$";
          };
          run = [
            "move-node-to-workspace C"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.github.wez.wezterm";
          };
          run = [
            "move-node-to-workspace T"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "com.mitchellh.ghostty";
          };
          run = [
            "move-node-to-workspace T"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "org.gnu.Emacs";
          };
          run = [
            "move-node-to-workspace E"
          ];
        }
        {
          check-further-callbacks = false;
          "if" = {
            app-id = "info.sioyek.sioyek";
          };
          run = [
            "move-node-to-workspace P"
          ];
        }
      ];
    
    mode.main.binding = {
        cmd-alt-h = [ ];

        alt-tab = "workspace-back-and-forth";

        # alt-left = "focus left";
        # alt-down = "focus down";
        # alt-up = "focus up";
        # alt-right = "focus right";

        # ctrl-cmd-shift-left = "move left";
        # ctrl-cmd-shift-down = "move down";
        # ctrl-cmd-shift-up = "move up";
        # ctrl-cmd-shift-right = "move right";

        ctrl-cmd-shift-0 = "balance-sizes";

        ctrl-alt-cmd-shift-0 = "workspace 0";
        ctrl-alt-cmd-shift-1 = "workspace 1";
        ctrl-alt-cmd-shift-2 = "workspace 2";
        ctrl-alt-cmd-shift-3 = "workspace 3";
        ctrl-alt-cmd-shift-4 = "workspace 4";
        ctrl-alt-cmd-shift-5 = "workspace 5";
        ctrl-alt-cmd-shift-c = "workspace C";
        ctrl-alt-cmd-shift-e = "workspace E";
        ctrl-alt-cmd-shift-n = "workspace N";
        ctrl-alt-cmd-shift-o = "workspace O";
        # ctrl-alt-cmd-shift-p = "workspace P";
        ctrl-alt-cmd-shift-t = "workspace T";
        ctrl-alt-cmd-shift-w = "workspace W";
        
        alt-shift-0 = [
          "move-node-to-workspace 0"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-1 = [
          "move-node-to-workspace 1"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-2 = [
          "move-node-to-workspace 2"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-3 = [
          "move-node-to-workspace 3"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-4 = [
          "move-node-to-workspace 4"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-5 = [
          "move-node-to-workspace 5"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-c = [
          "move-node-to-workspace C"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-e = [
          "move-node-to-workspace E"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-n = [
          "move-node-to-workspace N"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-o = [
          "move-node-to-workspace O"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-p = [
          "move-node-to-workspace P"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-t = [
          "move-node-to-workspace T"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];
        alt-shift-w = [
          "move-node-to-workspace W"
          "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --trigger space_windows_change"
        ];

        ctrl-cmd-shift-space = "layout floating tiling";
        ctrl-cmd-shift-minus = "resize smart -50";
        ctrl-cmd-shift-equal = "resize smart +50";

        alt-leftSquareBracket = "join-with left";
        alt-rightSquareBracket = "join-with right";

        alt-slash = "layout horizontal vertical";

        ctrl-cmd-shift-r = "exec-and-forget ${pkgs.sketchybar}/bin/sketchybar --reload && aerospace reload-config";
      };
    };
  };
}