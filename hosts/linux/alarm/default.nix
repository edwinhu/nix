# Omarchy (Arch Linux on Asahi) desktop configuration
# Minimal nix config - dotfiles managed separately
{ config, pkgs, lib, user, userInfo, ... }:

let
  iconDir = ../../../modules/linux/desktop-icons;
in
{
  imports = [
    ../../../modules/shared/home-secrets.nix
    # chrome-cdp + readwise-reader-tools services. Cross-platform module: emits
    # systemd user services + a timer here (Linux) and launchd agents on macOS.
    ../../../modules/shared/reader-services.nix
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
    file.".local/share/applications/icons/OpenCode.svg".source = "${iconDir}/OpenCode.svg";
    file.".local/share/applications/icons/Docker.svg".source = "${iconDir}/Docker.svg";
    file.".local/share/applications/icons/Morgen.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon
    file.".local/share/applications/icons/Beeper.svg".source = "${iconDir}/Superhuman.svg";  # Using similar icon  
    file.".local/share/applications/icons/Superhuman.svg".source = "${iconDir}/Superhuman.svg";
    file.".local/share/applications/icons/Tailscale.svg".source = "${iconDir}/Tailscale.svg";
    file.".local/share/applications/icons/Tailscale Admin Console.png".source = "${iconDir}/Tailscale Admin Console.png";
    file.".local/share/applications/icons/YouTube Music.png".source = "${iconDir}/YouTube Music.png";
    file.".local/share/applications/icons/Strem.io.svg".source = "${iconDir}/Strem.io.svg";
    file.".local/share/applications/icons/Readwise Reader.png".source = "${iconDir}/Readwise Reader.png";
    file.".local/share/applications/icons/Calculator.svg".source = "${iconDir}/Calculator.svg";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts
  fonts.fontconfig.enable = true;

  # hints config: vimium-style hint appearance + per-app coordinate scaling.
  # On this 2x HiDPI output, Chromium-family apps (the browser, chrome-web.*
  # PWAs, and Electron apps like Beeper/Morgen) report accessibility coords in
  # physical pixels, so the default scale_factor is 0.5. Genuinely-native GTK/Qt
  # apps report logical coords and are whitelisted back to 1.0. The atspi
  # backend is the only one enabled (opencv visual-detection produced misaligned
  # duplicates and isn't needed now that apps expose accessibility). Add a
  # "<window-class>".scale_factor = 1 entry for any native app that hints wrong.
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
          # Atspi.CollectionMatchType.ANY) instead of the upstream default,
          # which hints everything except containers — that pulled in images,
          # static text, headings, table cells, etc. and cluttered dense
          # Chromium/Electron apps (e.g. Beeper). Atspi.Role int values:
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
        # Beeper: hint only what's useful for keyboard navigation — the
        # conversation threads (FOCUSABLE `section` role 85) plus the message
        # composer (entry role 79). Buttons (role 43) are dropped because Beeper
        # renders ~60 per-message action buttons in the conversation pane (the
        # "extra chat hints" clutter) that share the button role with the useful
        # sidebar buttons and can't be separated by role/state — only by screen
        # position, which the config can't filter on. Require FOCUSABLE (11) +
        # SENSITIVE (24) + SHOWING (25), states_match_type 1 = ALL, so only the
        # real ~13 thread rows match (not the 70+ decorative sections).
        # scale_factor (0.5) inherits from the default rule.
        "BeeperTexts" = {
          roles = [ 85 79 ];
          roles_match_type = 2;
          states = [ 24 25 11 ];
          states_match_type = 1;
        };
      };
    };
  };

  # Enable home-manager
  programs.home-manager.enable = true;

  # Global accessibility toggle. Chromium/Electron/Qt apps only publish their
  # AT-SPI accessibility tree when assistive tech is marked active on the a11y
  # bus (org.a11y.Status.IsEnabled). Without this, `hints` gets no real elements
  # for those apps and falls back to opencv edge-detection (misaligned dupes).
  # GTK apps expose it regardless, so this is what makes hints work everywhere.
  dconf.settings = {
    "org/gnome/desktop/interface".toolkit-accessibility = true;
  };

  # Run the hints daemon as part of the graphical session (replaces the manual
  # `exec-once = hintsd` in ~/.config/hypr/autostart.conf). uwsm exports the
  # Wayland/D-Bus env into the systemd user manager, so graphical-session.target
  # services inherit WAYLAND_DISPLAY etc. hintsd needs /dev/input (evdev) access,
  # i.e. the user in the `input` group — host/OS config, not managed here.
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

  # swlinux dictation: fetch the (large, non-store) models once, then run the
  # daemon as a graphical-session service. Keybinds live in the user's Hyprland
  # config (SUPER+; = cleanup, SUPER+SHIFT+; = raw), like the hints keybinds.
  home.activation.swlinuxModels = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    MODELS="$HOME/.local/share/swlinux/models"
    $DRY_RUN_CMD mkdir -p "$MODELS"
    # Parakeet v3 (multilingual STT)
    if [ ! -d "$MODELS/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fL --retry 3 -o "$MODELS/p.tar.bz2" \
        https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2 \
        && $DRY_RUN_CMD ${pkgs.gnutar}/bin/tar -xjf "$MODELS/p.tar.bz2" -C "$MODELS" \
        && $DRY_RUN_CMD rm -f "$MODELS/p.tar.bz2"
    fi
    # Local cleanup LLM (open Qwen2.5-1.5B; ≈ superwhisper's S1-Mini)
    if [ ! -f "$MODELS/qwen2.5-1.5b-instruct-q4.gguf" ]; then
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fL --retry 3 -o "$MODELS/qwen2.5-1.5b-instruct-q4.gguf" \
        https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf
    fi
  '';

  systemd.user.services.swlinux = {
    Unit = {
      Description = "swlinux dictation daemon (Parakeet STT + local cleanup)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.swlinux}/bin/swlinux daemon";
      Restart = "on-failure";
      RestartSec = 2;
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

    # Morgen runs as a Chromium PWA (web.morgen.so) rather than the native
    # Electron app, so the real Vimium extension handles in-page keyboard
    # navigation (superior to hints for web content). The native app + its
    # autostart were removed; keybind SUPER+SHIFT+C launches this webapp.
    morgen = {
      name = "Morgen";
      comment = "Calendar and Tasks";
      exec = "omarchy-launch-webapp https://web.morgen.so/";
      terminal = false;
      type = "Application";
      icon = "morgen";
      categories = [ "Utility" ];
    };

    beepertexts = {
      name = "Beeper";
      comment = "Beeper messaging app";
      exec = "beeper --force-renderer-accessibility %U";  # expose a11y tree to hints (Electron)
      terminal = false;
      type = "Application";
      icon = "beeper";
      categories = [ "Network" ];
      mimeType = [ "x-scheme-handler/beeper" ];
    };

    superhuman = {
      name = "Superhuman";
      comment = "Superhuman email client";
      exec = "/usr/bin/chromium --profile-directory=Default --app-id=cabkgbgkeonbpeoedbaeolhgfkempoka";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Superhuman.svg";
      startupNotify = true;
    };

    tailscale = {
      name = "Tailscale";
      comment = "Tailscale VPN";
      exec = "xdg-terminal-exec --app-id=TUI.float -e sudo tsui";
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

    stremio = {
      name = "Strem.io";
      comment = "Strem.io streaming";
      exec = "omarchy-launch-webapp https://web.strem.io/";
      terminal = false;
      type = "Application";
      icon = "${config.home.homeDirectory}/.local/share/applications/icons/Strem.io.svg";
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
