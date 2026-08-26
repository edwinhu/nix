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
    stremio-linux-shell

    # AirPlay 2 bridge to the KEF (PipeWire's RAOP is AirPlay 1 only).
    # Wiring + the required ufw rule: hosts/linux/omarchy/default.nix.
    owntone

    # Tailscale TUI (source build). Terminal workspaces are herdr's job now —
    # it's cross-platform, so it lives in modules/shared/packages.nix.
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

    # Mail. The UVA tenant refuses IMAP/SMTP but DOES issue Mail-scoped
    # Microsoft Graph tokens, so the two clients take different work paths:
    # himalaya goes direct to Graph (ortie brokers the token), while aerc —
    # which speaks IMAP only — still reads through mail-bridge's loopback IMAP
    # (a user service brings it up) and sends through its sendmail(1) shim.
    # Personal Gmail goes direct for both. aerc is the TUI,
    # himalaya the scriptable one. Configs for both are declared in the omarchy
    # host.
    #
    # himalaya is pinned to v2 by the Linux overlay in flake.nix. v2 is a pure
    # protocol client: composing and rendering moved out to mml, which is why
    # the two are listed together.
    #
    # aerc here REPLACES pacman's (`sudo pacman -Rns aerc`): a second copy in
    # /usr/bin would shadow-or-be-shadowed by PATH order, and nix owns the
    # config now. It is not in providedByOmarchyBase for that reason — that list
    # is for tools the base install ships and we defer to.
    aerc
    himalaya
    mml
    # ortie brokers the work account's Microsoft Graph token. himalaya calls it
    # by store path from its config; this entry is for the bootstrap by hand
    # (`ortie -a msgraph auth get` / `auth resume`).
    ortie

    # chawan renders aerc's text/html (see aercChawanHtml in the omarchy host).
    # w3m stays even though the filter no longer uses it: aerc's OWN shipped
    # `html` filter shells out to it, so keeping it means that fallback still
    # works if the chawan filter is ever reverted or fails.
    chawan
    w3m

    # Outlook mailbox as loopback IMAP + sendmail(1) (gh:edwinhu/mail-bridge).
    # Source-built, so unlike the Bun-release CLIs below it needs no x86_64 gate.
    mail-bridge

    # File managers / PDF reader
    doublecmd
    ueberzugpp

    # Note-taking. nix-managed (nixGL-wrapped in flake.nix) instead of the Arch
    # `obsidian` package: the distro's electron39 breaks in-app PDF preview
    # (app:// CORS block). See the flake overlay comment for the full diagnosis.
    obsidian

    # Fonts / math typesetting extras
    lmmath
    maple-mono.NF
  ];

  # x86_64-linux ONLY — every one of these is distributed as a prebuilt x86-64
  # binary with no ARM64 Linux build published anywhere upstream.
  #
  # These MUST be gated, not merely "broken on aarch64". A package whose
  # meta.platforms excludes the host aborts the ENTIRE home-manager evaluation
  # the moment it appears in home.packages ("error: Refusing to evaluate package
  # … not available on the requested hostPlatform"), so a single x86-only entry
  # takes down every other package on the aarch64 Omarchy host (`alarm`, Asahi)
  # rather than just skipping itself. Add new prebuilt-binary packages HERE, not
  # to linuxOnly, unless you have confirmed an aarch64-linux artifact exists.
  #
  #   zoom-us        Zoom ships no ARM64 Linux client; use app.zoom.us instead.
  #   hylo           GH release is an x86_64 AppImage only.
  #   morgen-cli     \  own repos; Bun release CI publishes darwin-arm64 and
  #   paperpile-cli  /  linux-x64 but no linux-arm64. Bun CAN target
  #                     bun-linux-arm64 — adding that to each repo's
  #                     release.yml is the real fix, after which these move
  #                     back into linuxOnly.
  x86_64Only = with pkgs; [
    zoom-us
    hylo
    morgen-cli
    paperpile-cli
    # pinpoint, crumb: releases ship linux-x64 + darwin-arm64, no linux-arm64.
    pinpoint
    crumb
  ];
in
lib.subtractLists providedByOmarchyBase shared
++ linuxOnly
++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 x86_64Only
