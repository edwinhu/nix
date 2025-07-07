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

- SSH keys required: `id_ed25519` (general) and `id_ed25519_agenix` (secrets)
- Build scripts automatically detect current user and platform
- All secrets encrypted with agenix in separate private repository
- The flake uses nixpkgs-unstable channel for latest packages