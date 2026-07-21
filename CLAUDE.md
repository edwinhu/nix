# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Multi-user, multi-platform Nix configuration using nix-darwin (macOS) and home-manager (Linux) with agenix for secrets management.

## Primary Commands

```bash
# Main command - auto-detects user/platform and applies configuration
nix run .#build-switch

# Build configuration without switching (for testing)
nix run .#build

# Validate flake syntax and evaluate all outputs
nix flake check

# Update flake inputs
nix flake update              # Update all inputs
nix flake update nix-secrets  # Update only secrets
```

## Architecture

**Configuration Structure:**
- `flake.nix`: Central configuration with user definitions (`userInfo`) and host mappings (`userHosts`)
- `modules/shared/`: Cross-platform configurations (packages, home-manager, secrets)
- `modules/darwin/`: macOS-specific modules (aerospace, sketchybar, casks)
- `modules/linux/`: Linux-specific configurations
- `hosts/`: Host-specific hardware configurations
- `apps/`: Platform detection scripts for build commands

**Key Integration Points:**
- User configuration is centralized in `flake.nix` via `userInfo` (name, email, keys)
- Git and SSH configs in `modules/shared/home-manager.nix` automatically use `userInfo`
- No separate per-user configuration files needed (users/ directory removed)

**Package Management:**
- Cross-platform packages: `modules/shared/packages.nix`
- macOS CLI tools: `modules/darwin/packages.nix`
- macOS GUI apps: `modules/darwin/casks.nix` (via nix-homebrew)
- User-specific packages: Add to `home.packages` in platform modules

## Common Tasks

**Adding a new user:**
1. Add user info to `userInfo` in `flake.nix`
2. Map user to host in `userHosts`
3. Create host configuration in `hosts/`

**Managing secrets:**
1. Edit in `~/nix-secrets/` repository
2. Add public keys to `secrets.nix`
3. Update flake: `nix flake update nix-secrets`
4. Rebuild: `nix run .#build-switch`

**Modifying Sketchybar (macOS status bar):**
- Main config: `modules/darwin/sketchybar/sketchybarrc`
- Items: `modules/darwin/sketchybar/items/`
- Plugins: `modules/darwin/sketchybar/plugins/`

## Important Notes

- SSH auth: per-host on-disk keys in `~/dotfiles/.ssh/config_external` (wrds_nyu, wrds_uva, rjds, satori). YubiKey FIDO2 resident keys (`id_nfc_sk`, `id_nano_sk`) + `id_github` only for github.com. 1Password vault holds recovery copies of all software keys. FIDO2 keys recoverable on a fresh machine via `ssh-keygen -K` from the YubiKey itself.
- Agenix activation reads from `~/.ssh/id_ed25519_agenix`; also stored in 1Password as recovery.
- Git commit signing: SSH-format using `~/.ssh/id_github.pub` (zero-touch). YubiKey FIDO2 keys also trusted in `allowed_signers` for past/explicit signatures.
- Build scripts automatically detect current user and platform
- All secrets encrypted with agenix in separate private repository
- The flake uses nixpkgs-unstable channel for latest packages
- **nixGL wrap for GPU/GL apps on Omarchy (non-NixOS):** nixpkgs GUI apps that
  use GL/EGL/mpv (beeper, limux, stremio-linux-shell, …) fail on the Omarchy
  hosts with `MESA-LOADER: failed to open dri … gbm` or `failed to create EGL
  display` — a nix-built binary can't find the system Mesa/EGL driver because
  there's no `/run/opengl-driver`. Fix: wrap the app's binary in `nixGLIntel`
  (the `nixGL` flake input; `nixGLIntel` covers AMD/Intel Mesa) in the **Linux
  `homeConfigurations` overlay** in `flake.nix`. Pattern — `symlinkJoin` a
  `writeShellScriptBin "<bin>"` that `exec`s
  `${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/<bin> "$@"`
  over the base package (wrapper shadows `bin/<bin>` via first-path-wins; the
  package's `share/` icons+desktop entry come through unchanged). See the
  `beeper`, `limux`, and `stremio-linux-shell` overrides for working examples.
  nixGL is a no-op where the system GL driver is already found, so it's safe.
  - **Also patch the .desktop entry** if the app ships one whose `Exec`/`TryExec`
    hard-codes an ABSOLUTE store path to its own binary (e.g. limux's
    `dev.limux.linux.desktop`). The wrapper only fixes launches that resolve to
    `~/.nix-profile/bin/<app>` (relative `Exec=<app>`, terminal invocation) — a
    hard-coded absolute path bypasses the wrapper, so the launcher still hits the
    EGL error. Fix with a `symlinkJoin` `postBuild` that `sed`s the entry's
    Exec/TryExec from `${pkg}/bin/<app>` to `$out/bin/<app>` (see limux).
  - **GDK_SCALE double-scaling:** Omarchy sets `GDK_SCALE=2` globally
    (monitors.conf) for the 2x display. Apps that already honor the Wayland
    wl_output scale (e.g. limux/libghostty) then double-scale → huge UI. Fix per
    app in its wrapper: `exec env -u GDK_SCALE nixGLIntel ${pkg}/bin/<app> …`.
- **Nix GUI apps missing from Walker — no entry, or an entry with no icon
  (Omarchy):** after adding a GUI app to `home.packages`, it commonly either
  does not appear in Walker at all, or appears with a blank/generic icon. Both
  symptoms are the SAME root cause, and neither means the app is installed
  wrong: the files are present and correct (binary in `~/.nix-profile/bin`,
  `.desktop` in `~/.nix-profile/share/applications`, icons in
  `~/.nix-profile/share/icons/hicolor/*/apps/`). What is stale is the
  long-running launcher process — `elephant` indexes desktop entries at
  startup, and Walker's GTK icon theme is likewise loaded once at startup. Two
  properties of the nix profile keep both from ever noticing an update: every
  store file has mtime `1969-12-31`, so nothing looks stale by mtime; and a
  switch REPLACES `~/.nix-profile/share/{applications,icons}` with a new store
  path instead of writing into the old one, so an inotify watch on the previous
  directory never fires. Restarting elephant + Walker fixes both at once.
  Handled automatically by the `reindexWalker` home-manager activation in
  `hosts/linux/omarchy/default.nix` (`systemctl --user try-restart
  elephant.service app-walker@autostart.service`; `try-restart` is a no-op with
  no graphical session). By hand: `omarchy restart walker`.
  - **Diagnose from data, not the launcher UI.** Entry indexed:
    `elephant query "desktopapplications;<name>;5"`. Icon actually resolvable
    by GTK (this is the check that distinguishes a real packaging problem from
    a stale cache):
    ```
    python3 -c 'import gi;gi.require_version("Gtk","4.0")
    from gi.repository import Gtk,Gdk;Gtk.init()
    t=Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
    print(t.has_icon("<icon-name>"))'
    ```
    Take `<icon-name>` from the entry's `Icon=` key. Note `find` does NOT
    descend into symlinked directories and nix profiles are full of them — use
    `find -L` or you will conclude icons are missing when they are present.
  - **A live-system check can be invalidated mid-diagnosis.** If the config is
    applied from a worktree branch, any `build-switch` run from `main` (another
    session, a parallel job) reverts it — the app vanishes from the profile
    while Walker still shows a cached entry, which looks exactly like "installed
    but no icon". Confirm what is actually live before diagnosing:
    `ls -l ~/.nix-profile/bin/<app>` and `ls -lat ~/.local/state/nix/profiles/`.
