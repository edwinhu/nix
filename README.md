# Multi-User, Multi-Platform Nix Configuration

This repository contains a Nix configuration that supports multiple users across different platforms, using [Determinate Nix 3.0](https://github.com/determinateSystems/nix-installer), [home-manager](https://github.com/nix-community/home-manager), and [nix-darwin](https://github.com/LnL7/nix-darwin) for macOS or standalone home-manager for Linux.

## Features

- **Multi-user support:** Each user has their own configuration with personal settings, packages, and secrets.
- **Multi-platform:** Supports both macOS (via nix-darwin) and Linux (via standalone home-manager).
- **Minimal setup:** Focused on simplicity and maintainability.
- **Determinate Nix 3.0:** Uses the latest installer for a reliable and reproducible Nix installation.
- **nix-darwin:** Manages macOS system configuration declaratively.
- **home-manager:** Manages user-level configuration with flakes support.
- **Flakes enabled:** Uses Nix flakes for reproducible and modular configuration.
- **sops-nix:** Secure secrets management using age encryption for API keys and sensitive data.
- **Dynamic configuration:** Build scripts automatically detect the current user.

## Inspiration

This configuration is based on [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config), but has been updated to fix breaking changes and ensure compatibility with newer versions of Nix and related tools.

## Supported Platforms

- **macOS:** Full system management via nix-darwin + home-manager
- **Linux:** User environment management via standalone home-manager (tested on Ubuntu)
- **NixOS:** Not currently configured, but the structure supports it

## Usage

### Prerequisites

1. **Install Determinate Nix:**
   ```sh
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```

2. **Clone this repository:**
   ```sh
   git clone https://github.com/yourusername/nix-config.git
   cd nix-config
   ```

### For macOS Users

Build and switch to your configuration:
```sh
nix run .#build-switch
# Or explicitly: darwin-rebuild switch --flake .#yourusername
```

### For Linux Users

Build and activate home-manager configuration:
```sh
nix run .#build-switch-home
# Or explicitly: home-manager switch --flake .#yourusername
```

### Setting up Secrets (sops-nix)

1. Generate age key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Add your public key to `.sops.yaml`
3. Encrypt secrets: `sops secrets.yaml`
4. Rebuild your configuration

## Configuration Structure

- `flake.nix` - Main configuration with user-host mappings
- `hosts/` - Host-specific configurations
  - `darwin/` - macOS hosts
  - `linux/` - Linux hosts
- `users/` - User-specific configurations
- `modules/` - Shared and platform-specific modules
  - `shared/` - Cross-platform configurations
  - `darwin/` - macOS-specific modules
  - `linux/` - Linux-specific modules

See [README-multiuser.md](README-multiuser.md) for detailed multi-user setup instructions.

## References

- [Determinate Nix Installer](https://github.com/determinateSystems/nix-installer)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [home-manager](https://github.com/nix-community/home-manager)
- [sops-nix](https://github.com/Mic92/sops-nix)
- [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)

---
Feel free to fork and adapt for your own needs!
