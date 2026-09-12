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
#   source builds) that don't belong in the shared list. It is split into the
#   SAME layers as the shared list so a profile means the same thing on both
#   sides: `full` is the main machine (omarchy), `client` is a box that only
#   runs LLM CLIs and `herdr --remote`.
#
# Adding a cross-platform tool now means editing shared/packages.nix ONLY; it
# reaches this host automatically unless the base already provides it.
{ pkgs, profile ? "full" }:

let
  inherit (pkgs) lib;

  shared = import ../shared/packages.nix { inherit pkgs profile; };

  # CLI tools the Omarchy base install already ships via pacman (checked in
  # /usr/bin). Excluded so the nix copy doesn't shadow the distro's identical
  # binary. Also: nodejs (managed by mise), neovim (nvim from base).
  providedByOmarchyBase = with pkgs; [
    # The login shell here is /usr/bin/zsh; the core layer's copy exists for
    # hosts where nix owns the shell, and must not shadow the distro one.
    zsh
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
  linuxLayers = with pkgs; {

    # Every Omarchy host, thin ones included.
    core = [
      # Wired-NIC diagnostics: link-detected, negotiated speed/duplex. Not in the
      # Omarchy base; `carrier`/operstate in /sys answer "is there a link" without
      # it, but ethtool is what reads the negotiated rate.
      ethtool

      # Tailscale TUI (source build). Terminal workspaces are herdr's job now —
      # it's cross-platform, so it lives in modules/shared/packages.nix. A
      # client profile reaches the main machine over the tailnet, so this is
      # part of its floor, not an extra.
      tsui
    ];

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
    mail = [
      aerc
      himalaya
      mml
      # himalaya-tui is himalaya v2's TUI front end. Built from source by the
      # Linux overlay: upstream has cut no release, so there is no tarball to
      # unpack.
      himalaya-tui
      # neverest syncs the mailboxes (himalaya v1's `account sync`, split out).
      # Also a source build, and for a different reason: its msgraph backend is
      # behind a non-default cargo feature, so upstream's released binary cannot
      # reach the work account.
      neverest
      # isync/mbsync pulls both mailboxes down to Maildir under ~/areas/mail, so
      # himalaya reads local files instead of a network backend: work over
      # mail-bridge's loopback IMAP (Graph is the only door the tenant opens),
      # personal straight off imap.gmail.com. Config: ~/.mbsyncrc, generated in
      # the omarchy host; driven by the mbsync-pull timer there. One-way pull —
      # the far side is never written.
      isync
      # notmuch: one index over both maildirs under ~/areas/mail, so aerc's
      # [Notmuch] account can offer SAVED SEARCHES where the bridge used to offer
      # virtual folders. A query costs nothing on disk; a virtual folder costs one
      # copy of every message per view mbsync pulls it into, which is why they
      # were dropped at the Maildir migration.
      #
      # Indexed by the mbsync-pull timer's companion `notmuch new` -- see the
      # omarchy host. Config: xdg.configFile "notmuch/default/config" there.
      notmuch
      # XOAUTH2 SASL plugin for the cyrus-sasl mbsync links against. Without it
      # the personal channel dies with "No worthy mechs found" — the mech list
      # mbsync offers has no XOAUTH2 at all. The plugin is discovered via
      # SASL_PATH, set on mbsync-pull.service in the omarchy host.
      cyrus-sasl-xoauth2
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

      # `O` in aerc's [view] opens the message in terminal-browser inside aerc's
      # own :term. Two scripts, because :term is given a pty but no stdin from the
      # mail: aerc-mail-serve takes the message over `:pipe -m -b` and records a
      # URL, aerc-html-terminal-browser launches the browser on it. See
      # modules/linux/aerc-html-terminal-browser.nix for why a text/html FILTER
      # cannot do this -- a filter gets pipes, and terminal-browser names its pane
      # from the pts on its stdin.
      aerc-html-terminal-browser

      # Outlook mailbox as loopback IMAP + sendmail(1) (gh:edwinhu/mail-bridge).
      # Source-built, so unlike the Bun-release CLIs below it needs no x86_64 gate.
      mail-bridge
    ];

    # Communication and media.
    media = [
      beeper
      stremio-linux-shell

      # AirPlay 2 bridge to the KEF (PipeWire's RAOP is AirPlay 1 only).
      # Wiring + the required ufw rule: hosts/linux/omarchy/default.nix.
      owntone

      # Terminal music player. REPLACES the AUR package (`sudo pacman -Rns
      # cliamp`): two copies would fight over PATH order, and the nix build is
      # the patched one — a resolved-URL cache that makes Next/Prev on YouTube
      # tracks near-instant. See modules/linux/cliamp-ytdl-cache.nix.
      cliamp
    ];

    # Desktop: GUI automation, file managers, fonts, Bluetooth.
    desktop = [
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

      # File managers / PDF reader
      doublecmd
      ueberzugpp

      # Fonts / math typesetting extras
      lmmath
      maple-mono.NF
    ];

    # Personal knowledge management.
    pkm = [
      # Note-taking. nix-managed (nixGL-wrapped in flake.nix) instead of the Arch
      # `obsidian` package: the distro's electron39 breaks in-app PDF preview
      # (app:// CORS block). See the flake overlay comment for the full diagnosis.
      obsidian
    ];
  };

  # x86_64-linux ONLY — every one of these is distributed as a prebuilt x86-64
  # binary with no ARM64 Linux build published anywhere upstream.
  #
  # These MUST be gated, not merely "broken on aarch64". A package whose
  # meta.platforms excludes the host aborts the ENTIRE home-manager evaluation
  # the moment it appears in home.packages ("error: Refusing to evaluate package
  # … not available on the requested hostPlatform"), so a single x86-only entry
  # takes down every other package on the aarch64 Omarchy host (`alarm`, Asahi)
  # rather than just skipping itself. Add new prebuilt-binary packages HERE, not
  # to linuxLayers, unless you have confirmed an aarch64-linux artifact exists.
  #
  #   zoom-us        Zoom ships no ARM64 Linux client; aarch64 hosts get the
  #                  app.zoom.us web app instead (Zoom entry in hosts/linux/alarm).
  #   hylo           GH release is an x86_64 AppImage only.
  #   morgen-cli     \  own repos; Bun release CI publishes darwin-arm64 and
  #   paperpile-cli  /  linux-x64 but no linux-arm64. Bun CAN target
  #                     bun-linux-arm64 — adding that to each repo's
  #                     release.yml is the real fix, after which these move
  #                     back into linuxLayers.
  x86_64OnlyLayers = with pkgs; {
    desktop = [ zoom-us ];
    pkm = [
      hylo
      morgen-cli
      paperpile-cli
      # pinpoint, crumb: releases ship linux-x64 + darwin-arm64, no linux-arm64.
      pinpoint
      crumb
    ];
  };

  # Same profile names as shared/packages.nix. `full` must be every layer.
  profiles = {
    full   = builtins.attrNames linuxLayers;
    client = [ "core" ];
  };

  selected = profiles.${profile} or (throw
    "omarchy-packages.nix: unknown profile '${profile}'; known: ${
      lib.concatStringsSep ", " (builtins.attrNames profiles)}");

  pick = set: lib.concatMap (name: set.${name} or []) selected;
in
assert lib.assertMsg (profiles.full == builtins.attrNames linuxLayers)
  "omarchy-packages.nix: the `full` profile must list every layer";
assert lib.assertMsg
  (lib.all (n: lib.elem n (builtins.attrNames linuxLayers))
    (builtins.attrNames x86_64OnlyLayers))
  "omarchy-packages.nix: every x86_64-only layer must also exist in linuxLayers";
lib.subtractLists providedByOmarchyBase shared
++ pick linuxLayers
++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 (pick x86_64OnlyLayers)
