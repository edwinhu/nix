# Omarchy (Arch Linux) on Framework Desktop (AMD Ryzen AI Max, x86_64)
# Minimal nix config - dotfiles managed separately.
# Modeled on hosts/linux/alarm (the aarch64/Asahi Omarchy host); the two share
# the same Omarchy desktop-entry + package set and differ only by architecture,
# which is handled in flake.nix (userHosts + the doublecmd/beeper overlays).
{ config, pkgs, lib, user, userInfo, ... }:

let
  iconDir = ../../../modules/linux/desktop-icons;

  # Morgen ships no usable icon (its iconDir entry was a Superhuman placeholder),
  # so pull the real one from the web app's apple-touch-icon (a real 180px PNG).
  # Superhuman uses the committed iconDir Superhuman.png — a 512px raster rendered
  # from the brand SVG (rsvg-convert -w 512). The SVG itself has only a 23px
  # viewBox in a <symbol>+<use>, which icon loaders rasterize at that low res ->
  # blurry on a 2x HiDPI display; the 512px PNG stays crisp at any launcher size.
  # (The mail.superhuman.com apple-touch-icon URL returns HTML, not an image.)
  morgenIcon = pkgs.fetchurl {
    url = "https://web.morgen.so/apple-touch-icon.png";
    hash = "sha256-MiLXn1LrP/9idaof4t2fAAADyh3+qw9bdqMva2h7LPE=";
  };
in
{
  imports = [
    ../../../modules/shared/home-secrets.nix
  ];

  # Basic home-manager configuration
  home = {
    stateVersion = "25.05";

    # Cherry-picked packages not in Omarchy/pacman
    packages = (import ../../../modules/linux/omarchy-packages.nix { inherit pkgs; });

    # Icon theme symlinks (Papirus installed via home-manager, needs symlinks)
    file.".local/share/icons/Papirus".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus";
    file.".local/share/icons/Papirus-Dark".source = "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark";

    # Install desktop entry icons
    file.".local/share/applications/icons/OpenCode.svg".source = "${iconDir}/Docker.svg";  # Placeholder until we have OpenCode icon
    file.".local/share/applications/icons/Docker.svg".source = "${iconDir}/Docker.svg";
    file.".local/share/applications/icons/Morgen.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Beeper.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Superhuman.svg".source = "${iconDir}/Superhuman.svg";
    file.".local/share/applications/icons/Tailscale.svg".source = "${iconDir}/Tailscale.svg";
    file.".local/share/applications/icons/Tailscale Admin Console.png".source = "${iconDir}/Tailscale Admin Console.png";
    file.".local/share/applications/icons/YouTube Music.png".source = "${iconDir}/YouTube Music.png";
    file.".local/share/applications/icons/Readwise Reader.png".source = "${iconDir}/Readwise Reader.png";
    file.".local/share/applications/icons/Calculator.svg".source = "${iconDir}/Calculator.svg";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts
  fonts.fontconfig.enable = true;

  # Enable home-manager
  programs.home-manager.enable = true;

  # Both CDP CLIs target the browser-wide endpoint (chromium-flags.conf, :9222).
  # superhuman-cli auto-probes 9222, but morgen-cli defaults to 9253 — point it
  # here. Host-scoped: the Mac uses native apps on 9252/9253, so this only
  # belongs on omarchy where everything shares the one Chromium CDP port.
  home.sessionVariables.CDP_PORT = "9222";

  # hints (keyboard-driven GUI navigation). Config, accessibility toggle and the
  # hintsd daemon service mirror hosts/linux/alarm — see there for the rationale
  # behind the role/state allow-lists. hintsd needs the user in the `input` group
  # (host/OS config, not managed here).
  xdg.configFile."hints/config.json".text = builtins.toJSON {
    hints = {
      hint_height = 22;
      hint_font_size = 11;
      hint_font_face = "Sans";
      hint_upercase = true;
      hint_background_r = 1.0;
      hint_background_g = 0.86;
      hint_background_b = 0.24;
      hint_background_a = 0.95;
      hint_font_r = 0.18;
      hint_font_g = 0.13;
      hint_font_b = 0.02;
      hint_font_a = 1.0;
      hint_pressed_font_r = 0.72;
      hint_pressed_font_g = 0.6;
      hint_pressed_font_b = 0.25;
      hint_pressed_font_a = 1.0;
    };
    backends = {
      enable = [ "atspi" ];
      atspi.application_rules = {
        default = {
          scale_factor = 0.5;
          # Allow-list only genuinely-interactive roles (roles_match_type 2 =
          # Atspi.CollectionMatchType.ANY). Atspi.Role int values:
          #   43 push button   88 link          79 entry        7 check box
          #   44 radio button  11 combo box     62 toggle btn  35 menu item
          #    8 check menuitem 45 radio menuitem 37 page tab   32 list item
          #   51 slider        52 spin button
          roles_match_type = 2;
          roles = [ 43 88 79 7 44 11 62 35 8 45 37 32 51 52 ];
        };
        "dev.limux.linux".scale_factor = 1;
        "doublecmd".scale_factor = 1;
        "org.gnome.Nautilus".scale_factor = 1;
        # Beeper: hint only conversation threads (FOCUSABLE `section` role 85)
        # plus the composer (entry role 79); require FOCUSABLE (11) + SENSITIVE
        # (24) + SHOWING (25), states_match_type 1 = ALL. See alarm for details.
        "BeeperTexts" = {
          roles = [ 85 79 ];
          roles_match_type = 2;
          states = [ 24 25 11 ];
          states_match_type = 1;
        };
      };
    };
  };

  # Global accessibility toggle. Chromium/Electron/Qt apps only publish their
  # AT-SPI accessibility tree when assistive tech is marked active on the a11y
  # bus (org.a11y.Status.IsEnabled). Without this, `hints` gets no real elements
  # for those apps and falls back to opencv edge-detection (misaligned dupes).
  dconf.settings = {
    "org/gnome/desktop/interface".toolkit-accessibility = true;
  };

  # Chromium flags (Arch's chromium wrapper appends every line to each launch).
  # Reproduces the Omarchy defaults and adds browser-wide CDP: the main Default
  # profile (already logged in) owns the debug endpoint on :9222, and every
  # app window (Superhuman, Morgen, etc. launched via omarchy-launch-webapp)
  # is a page on that one endpoint — so superhuman-cli (probes 9222) and
  # morgen-cli (CDP_PORT=9222) read tokens from the live session, no per-app
  # profile or manual re-login. force = it seeds a real file at install time.
  # SECURITY: this leaves a CDP port open on localhost whenever Chromium runs;
  # any local process can drive the browser. Acceptable on a personal machine;
  # scoped to this host only (not in shared dotfiles).
  xdg.configFile."chromium-flags.conf" = {
    force = true;
    text = ''
      --ozone-platform=wayland
      --ozone-platform-hint=wayland
      --enable-features=TouchpadOverscrollHistoryNavigation
      --load-extension=~/.local/share/omarchy/default/chromium/extensions/copy-url
      --remote-debugging-port=9222
      --remote-allow-origins=*
    '';
  };

  # Machine-specific Hyprland/audio config, managed here (not shared dotfiles)
  # because it's tied to THIS box's hardware — the DCN31 GPU + BenQ display and
  # the ALC623 audio codec — and would be wrong on the alarm host. force = true
  # overrides the Omarchy-seeded defaults. See each file for the rationale.
  #   - hypridle.conf: never dpms-off the panel (DCN31 dp_blank wedge workaround)
  #   - monitors.conf: DP-4 @ preferred(144), scale 2
  #   - 50-prefer-hdmi.conf: disable onboard analog out, prefer HDMI/DP audio
  xdg.configFile."hypr/hypridle.conf" = { source = ./files/hypridle.conf; force = true; };
  xdg.configFile."hypr/monitors.conf" = { source = ./files/monitors.conf; force = true; };
  xdg.configFile."wireplumber/wireplumber.conf.d/50-prefer-hdmi.conf" = {
    source = ./files/wireplumber-prefer-hdmi.conf;
    force = true;
  };

  # Run the hints daemon as part of the graphical session (replaces the manual
  # `exec-once = hintsd` in ~/.config/hypr/autostart.conf). uwsm exports the
  # Wayland/D-Bus env into the systemd user manager, so graphical-session.target
  # services inherit WAYLAND_DISPLAY etc.
  systemd.user.services.hintsd = {
    Unit = {
      Description = "Hints daemon (keyboard GUI navigation)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.hints}/bin/hintsd";
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Stremio streaming server (the "download-service" / server.js that actually
  # streams+transcodes for the web app at web.strem.io). Not in nixpkgs; run the
  # official docker image as a graphical-session user service on :11470, which
  # web.strem.io auto-detects. Uses the system docker daemon (/usr/bin/docker;
  # user is in the docker group). ExecStartPre clears any stale container.
  #
  # NAMED volume `stremio-cache` (not an anonymous one) so the on-disk cache and
  # settings survive `--rm` across restarts/reboots — keeps the buffer warm.
  # ExecStartPost bumps the cache/buffer to 10 GiB (default is 2 GiB) so streams
  # buffer far enough ahead to avoid stalls on source-speed dips.
  systemd.user.services.stremio-server = {
    Unit = {
      Description = "Stremio streaming server (docker)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStartPre = "-/usr/bin/docker rm -f stremio-server";
      ExecStart = "/usr/bin/docker run --rm --name stremio-server -v stremio-cache:/root/.stremio-server -p 11470:11470 -p 12470:12470 stremio/server:latest";
      ExecStartPost = "${pkgs.bash}/bin/bash ${./files/stremio-tune.sh}";
      ExecStop = "/usr/bin/docker stop stremio-server";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Desktop entries - only the custom ones not provided by Omarchy
  xdg.desktopEntries = {
    opencode = {
      name = "OpenCode";
      comment = "The open source AI coding agent";
      exec = "${pkgs.opencode}/bin/opencode";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/OpenCode.svg";
      categories = [ "Development" "IDE" ];
      startupNotify = true;
    };

    docker = {
      name = "Docker";
      comment = "Docker container management";
      exec = "xdg-terminal-exec --app-id=TUI.tile -e lazydocker";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Docker.svg";
      startupNotify = true;
    };

    # Morgen as a Chromium PWA (web.morgen.so) rather than the native tarball at
    # ~/.local/opt/Morgen — no per-machine binary to maintain. Trade-off: the PWA
    # can't register the morgen:// scheme or handle .ics files, so mimeType is
    # dropped (the native app was the only thing that could claim those).
    # launch-or-focus (not plain launch): these web apps have single-instance
    # behaviour on the shared profile — a second launch would open a duplicate
    # tab that Morgen shows as "inactive". Matching on the window class/title
    # ("morgen") focuses the existing window instead.
    morgen = {
      name = "Morgen";
      comment = "Calendar and Tasks";
      exec = "omarchy-launch-or-focus-webapp morgen https://web.morgen.so";
      terminal = false;
      type = "Application";
      icon = "${morgenIcon}";
      categories = [ "Utility" ];
    };

    beepertexts = {
      name = "Beeper";
      comment = "Beeper messaging app";
      exec = "beeper %U";
      terminal = false;
      type = "Application";
      icon = "beeper";
      categories = [ "Network" ];
      mimeType = [ "x-scheme-handler/beeper" ];
    };

    # Superhuman as a Chromium app on the shared Default profile (where you're
    # already logged in). CDP is enabled browser-wide via chromium-flags.conf
    # below (one endpoint on :9222), so superhuman-cli attaches there — no
    # per-app profile or hardcoded --app-id needed.
    superhuman = {
      name = "Superhuman";
      comment = "Superhuman email client";
      exec = "omarchy-launch-or-focus-webapp superhuman https://mail.superhuman.com";
      terminal = false;
      type = "Application";
      icon = "${iconDir}/Superhuman.png";
      startupNotify = true;
    };

    # tsui (Tailscale TUI) in a floating terminal. Full store path because sudo
    # resets PATH and won't find the user nix-profile bin. Packaged from the
    # neuralink/tsui release (modules/shared/tsui.nix); needs passwordless sudo
    # for tsui or it'll prompt in the terminal.
    tailscale = {
      name = "Tailscale";
      comment = "Tailscale VPN";
      exec = "xdg-terminal-exec --app-id=TUI.float -e sudo ${pkgs.tsui}/bin/tsui";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale.svg";
      startupNotify = true;
    };

    tailscale-admin = {
      name = "Tailscale Admin Console";
      comment = "Tailscale Admin Console";
      exec = "omarchy-launch-webapp https://login.tailscale.com/admin/machines";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Tailscale Admin Console.png";
      startupNotify = true;
    };

    youtube-music = {
      name = "YouTube Music";
      comment = "YouTube Music";
      exec = "omarchy-launch-webapp https://music.youtube.com";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/YouTube Music.png";
      startupNotify = true;
    };

    readwise-reader = {
      name = "Readwise Reader";
      comment = "Readwise Reader";
      exec = "omarchy-launch-webapp https://read.readwise.io/";
      terminal = false;
      type = "Application";
      icon = "readwise-reader";
      startupNotify = true;
    };

    calculator = {
      name = "Calculator (Numr)";
      comment = "Numr - vim-style calculator";
      exec = "xdg-terminal-exec --app-id=TUI.tile -e ${pkgs.numr}/bin/numr";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Calculator.svg";
      startupNotify = true;
    };
  };
}
