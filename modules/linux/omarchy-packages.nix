# Packages for Omarchy (Arch Linux) systems.
#
# Computed as a DELTA over the cross-platform list, so there is a single source
# of truth (modules/shared/packages.nix) and no hand-maintained duplication:
#
#     omarchy = (shared − providedByOmarchyBase) ++ linuxOnly
#
# - shared/packages.nix owns every cross-platform CLI tool.
# - providedByOmarchyBase lists the tools the Omarchy base install already ships
#   via pacman (verified in /usr/bin); we drop the nix copy so it doesn't shadow
#   an identical distro binary. This is the ONLY pacman-vs-nix knob.
# - linuxOnly holds omarchy-specific additions (GUI apps, Wayland input tools,
#   source builds) that don't belong in the shared list.
#
# Adding a cross-platform tool now means editing shared/packages.nix ONLY; it
# reaches this host automatically unless the base already provides it.
{ pkgs }:

let
  inherit (pkgs) lib;

  shared = import ../shared/packages.nix { inherit pkgs; };

  # CLI tools the Omarchy base install already ships via pacman (checked in
  # /usr/bin). Excluded so the nix copy doesn't shadow the distro's identical
  # binary. Also: nodejs (managed by mise), neovim (nvim from base).
  providedByOmarchyBase = with pkgs; [
    neovim
    gh
    lazygit
    bat
    eza
    fd
    fzf
    ripgrep
    starship
    zoxide
    btop
    jq
    tldr
    zip
    unzip
    dust
    nodejs
  ];

  # Omarchy/Linux-only additions: GUI apps, Wayland input simulation, and
  # source-built tools not in the shared (cross-platform) list. Several GL apps
  # here are nixGL-wrapped in flake.nix's Linux overlay (see nix/CLAUDE.md).
  linuxOnly = with pkgs; [
    # Communication / media
    beeper
    # Zoom (nixpkgs zoom-us wrapped in nixGL — see flake overlay). Ships
    # Zoom.desktop + zoommtg:// handlers; screen-share via xdg-desktop-portal-hyprland.
    zoom-us
    superhuman-cli
    morgen-cli
    paperpile-cli
    stremio-linux-shell

    # Terminal workspace / tailscale TUI (source builds)
    limux
    tsui

    # Bluetooth CLI. The Omarchy/Arch base ships only the bluez *daemon*
    # (bluetoothd); bluetoothctl lives in the separate bluez-utils package,
    # which isn't installed — so provide the full bluez here for the CLI.
    # Used by ~/projects/joycon-pad/pair-joycon.sh and ad-hoc pairing. The
    # systemd bluetooth.service still runs the distro daemon (absolute path),
    # so this adds only the client tools to PATH; no second daemon.
    bluez

    # GUI automation / input simulation (Wayland + X11)
    dotool
    xdotool
    ydotool
    hints

    # Local Wayland dictation (gh:edwinhu/superwhisper-linux)
    swlinux

    # Dictation + AI meeting notes; the Linux stand-in for the macOS-only
    # granola cask (nixGL-wrapped in flake.nix).
    openwhispr

    # File managers / PDF reader
    doublecmd
    hylo
    ueberzugpp

    # Fonts / math typesetting extras
    lmmath
    maple-mono.NF
  ];
in
lib.subtractLists providedByOmarchyBase shared ++ linuxOnly
