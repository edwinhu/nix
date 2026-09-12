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

## Profiles

Each host names a `profile` in `userHosts` (flake.nix): `full` (omarchy, the
main machine, and the Macs), `client` (alarm — LLM CLIs plus `herdr --remote`),
`server` (rjds — headless). The profile selects LAYERS from
`modules/shared/packages.nix` and `modules/linux/omarchy-packages.nix`; both
files assert that `full` covers every layer.

Put a new tool in exactly one layer. Slim a machine by changing its profile,
never by editing a package list. `client`/`server` also drop what references a
dropped package — a desktop entry or systemd unit naming one by store path pulls
it back in.

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
  use GL/EGL/mpv (beeper, ghostty, stremio-linux-shell, …) fail on the Omarchy
  hosts with `MESA-LOADER: failed to open dri … gbm` or `failed to create EGL
  display` — a nix-built binary can't find the system Mesa/EGL driver because
  there's no `/run/opengl-driver`. Fix: wrap the app's binary in `nixGLIntel`
  (the `nixGL` flake input; `nixGLIntel` covers AMD/Intel Mesa) in the **Linux
  `homeConfigurations` overlay** in `flake.nix`. Pattern — `symlinkJoin` a
  `writeShellScriptBin "<bin>"` that `exec`s
  `${nixGL.packages.${info.system}.nixGLIntel}/bin/nixGLIntel ${base}/bin/<bin> "$@"`
  over the base package (wrapper shadows `bin/<bin>` via first-path-wins; the
  package's `share/` icons+desktop entry come through unchanged). See the
  `beeper`, `ghostty`, and `stremio-linux-shell` overrides for working examples.
  nixGL is a no-op where the system GL driver is already found, so it's safe.
  - **Also patch the .desktop entry** if the app ships one whose `Exec`/`TryExec`
    hard-codes an ABSOLUTE store path to its own binary (e.g. ghostty's
    `com.mitchellh.ghostty.desktop`). The wrapper only fixes launches that resolve to
    `~/.nix-profile/bin/<app>` (relative `Exec=<app>`, terminal invocation) — a
    hard-coded absolute path bypasses the wrapper, so the launcher still hits the
    EGL error. Fix with a `symlinkJoin` `postBuild` that `sed`s the entry's
    Exec/TryExec from `${pkg}/bin/<app>` to `$out/bin/<app>` (see ghostty).
  - **GDK_SCALE double-scaling:** Omarchy sets `GDK_SCALE=2` globally
    (monitors.conf) for the 2x display. Apps that already honor the Wayland
    wl_output scale (e.g. ghostty/libghostty) then double-scale → huge UI. Fix per
    app in its wrapper: `exec env -u GDK_SCALE nixGLIntel ${pkg}/bin/<app> …`.
- **A nix GUI app missing from the Omarchy launcher is usually not a packaging
  bug.** Check the files first — binary in `~/.nix-profile/bin`, `.desktop` in
  `~/.nix-profile/share/applications`, icons in
  `~/.nix-profile/share/icons/hicolor/*/apps/`. Two traps when checking:
  `find` does NOT descend into symlinked directories and nix profiles are full
  of them, so use `find -L` or you will conclude icons are missing when they
  are present; and a `build-switch` run from another session or branch reverts
  what you just applied, so confirm what is live (`ls -l
  ~/.nix-profile/bin/<app>`, `ls -lat ~/.local/state/nix/profiles/`) before
  diagnosing. Omarchy 4's shell reads `DesktopEntries` across `XDG_DATA_DIRS`
  and watches for changes, so no launcher-reindex step is needed.

## Any claim about what aerc renders must come from a screenshot

`hosts/linux/omarchy/files/check-o-shot.sh <outdir>` is the ONLY instrument that
settles what is on screen. Run it, look at the PNGs yourself, and send them to
the user. Do not report a render as working on anything else.

Nothing else here can answer the question, and each of these was believed and
was wrong:

- `terminal-browser ls --json` reporting `splitDir=null` means the browser
  REGISTERED against the pane, not that it painted. A "passing" run's pane was
  blank.
- `herdr pane read` cannot see graphics at all: herdr composites kitty images
  itself, so a painted pane and an empty one are both zero bytes. Every
  escape-count and letter-count gate built on it was blind by construction.
- A filter that works standalone proves the pipe, not the pane. The sixel
  filter emits a valid 390KB DCS payload on the command line and still shows
  no image inside aerc.

The guards in that script exist because each failure below produced a confident
wrong report:

- **Right window.** Find the ghostty window DISPLAYING aerc via the herdr
  workspace label and its active tab. herdr titles a window after the workspace
  ("omarchy: assistant"), never the tab, so matching the title against "aerc"
  rejects the correct window; `clients[0]` photographs an unrelated session.
- **Liveness probe.** Move the cursor, require the pixels to change, over THREE
  frames (`j` on the last message legitimately changes nothing). A frozen frame
  is indistinguishable from a blank pane.
- **Never float the window.** A floated window returns a cached buffer: three
  frames and two runs apart all hashed identically.
- **A dead aerc looks exactly like a frozen screen** — its last frame stays in
  the pane. Check `ps -eo args= | grep -c '[b]in/aerc$'` before blaming the
  compositor.
- **Wait for the render.** The sixel filter goes through Chromium; shooting 2s
  after the header appears photographs the text and reports the image missing.

Driving aerc, hard-won:

- `o` is safe to send. **Enter in [view] is `:reply -a`** and has opened reply
  composers to newsletters. In [messages] `q` is `:prompt 'Quit?' quit`, not a
  close. Read the pane to decide state before sending any key; never on a timer.
- aerc runs as `.aerc-wrapped`, so `pkill -x aerc` reports success and kills
  nothing.
- `pkill -f <pattern>` matches the running script's own command line and kills
  the shell (exit 144). Collect explicit PIDs with `ps -eo pid=,args=` instead.
- Every `herdr` call prints a `mise` banner on stdout. Filter
  `^mise ~/.config/mise` or it is counted as pane content.
- `hyprctl dispatch` parses its argument as LUA on this build. Old spellings
  (`dispatch setfloating address:0x…`) fail with a syntax error printed to
  stdout and **exit 0**, so they look like they worked. The form that runs is
  `hyprctl dispatch "hl.dsp.window.float{window='address:0x…'}"`.

## aerc's text/html filter: what the `!` means

`!` runs the filter IN A TERMINAL. It is required for graphics — without it
aerc's pager strips the DCS introducer and a sixel payload prints as literal
`q"1;1;1248;540#0;2;91;91;91…`. It is also what made an interactive browser
overdraw the message view ("Maxmly," for "Max," over "Warmly,"). The rule is
not "avoid `!`", it is: **a filter must print its output and exit. Never put
something that repaints behind it.**

aerc renders **sixel**, not kitty. A kitty-graphics probe inside `:term` prints
its caption and no image; do not generalise that to "aerc has no graphics",
which contradicts the working sixel path.
