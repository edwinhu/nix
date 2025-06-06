# Minimal Nix Configuration

This repository contains a minimal Nix configuration that starts with [Determinate Nix 3.0](https://github.com/determinateSystems/nix-installer), and uses both [home-manager](https://github.com/nix-community/home-manager) and [nix-darwin](https://github.com/LnL7/nix-darwin) for macOS system and user environment management.

## Features

- **Minimal setup:** Focused on simplicity and maintainability.
- **Determinate Nix 3.0:** Uses the latest installer for a reliable and reproducible Nix installation.
- **nix-darwin:** Manages macOS system configuration declaratively.
- **home-manager:** Manages user-level configuration with flakes support.
- **Flakes enabled:** Uses Nix flakes for reproducible and modular configuration.
- **Up-to-date:** Updated to work with recent versions of Nix, nix-flakes, and home-manager.

## Inspiration

This configuration is based on [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config), but has been updated to fix breaking changes and ensure compatibility with newer versions of Nix and related tools.

## NixOS Support

While this setup is focused on macOS (nix-darwin + home-manager), it could be extended to support NixOS, but that is not currently used or tested here.

## Usage

1. **Install Determinate Nix:**
   ```sh
   curl -L https://nixos.org/nix/install | sh
   # or use the Determinate installer as per their documentation
   ```

2. **Clone this repository:**
   ```sh
   git clone https://github.com/yourusername/nix-config.git
   cd nix-config
   ```

3. **Set up nix-darwin and home-manager:**
   Follow the instructions in the respective modules and flake files.

## References

- [Determinate Nix Installer](https://github.com/determinateSystems/nix-installer)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [home-manager](https://github.com/nix-community/home-manager)
- [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)

---
Feel free to fork and adapt for your own needs!
