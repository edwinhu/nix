# Multi-User, Multi-Platform Nix Configuration

A comprehensive Nix configuration supporting multiple users across macOS and Linux platforms, featuring [Determinate Nix 3.0](https://github.com/determinateSystems/nix-installer), [home-manager](https://github.com/nix-community/home-manager), [nix-darwin](https://github.com/LnL7/nix-darwin), and secure secrets management with [sops-nix](https://github.com/Mic92/sops-nix).

## Features

- **Multi-user support**: Each user has independent configuration with personal settings, packages, and secrets
- **Multi-platform**: Full support for macOS (via nix-darwin) and Linux (via standalone home-manager)
- **Secure secrets**: Encrypted secrets management using age keys and sops-nix
- **Flakes enabled**: Modern Nix flakes for reproducible and modular configuration
- **Minimal setup**: Focused on simplicity and maintainability
- **Dynamic detection**: Build scripts automatically detect current user and platform

## Current Users

- **vwh7mb** on **macbook-pro** (macOS/Darwin, aarch64)
- **eh2889** on **rjds** (Ubuntu Linux, x86_64)

## Quick Start

### 1. Install Determinate Nix

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

### 2. Clone Repository

```bash
git clone <your-repository-url>
cd nix
```

### 3. Build and Switch

```bash
nix run .#build-switch
```

This command automatically detects:
- **macOS**: Uses `darwin-rebuild`
- **NixOS**: Uses `nixos-rebuild`
- **Other Linux**: Uses `home-manager` standalone

## Platform-Specific Commands

If you prefer explicit commands:

**macOS (nix-darwin)**
```bash
darwin-rebuild switch --flake .#vwh7mb
```

**Linux (home-manager standalone)**
```bash
home-manager switch --flake .#eh2889
```

**NixOS** (not currently configured)
```bash
sudo nixos-rebuild switch --flake .#<hostname>
```

## Secrets Management

This configuration uses sops-nix with age encryption for managing secrets like API keys.

### Initial Setup

1. **Generate age key** (if not already done):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_agenix -N ""
   ```

2. **Get your age public key**:
   ```bash
   ssh-to-age < ~/.ssh/id_ed25519_agenix.pub
   ```

3. **Set up private secrets repository**:
   ```bash
   # Create private GitHub repository
   gh repo create nix-secrets --private --description "Encrypted secrets for nix configuration"
   
   # Clone and set up
   cd ~/
   git clone git@github.com:YOUR_USERNAME/nix-secrets.git
   cd nix-secrets
   ```

4. **Configure secrets files**:
   - Copy `.sops.yaml` and `secrets.yaml` from this repository
   - Update `.sops.yaml` with your age public key
   - Edit secrets using: `sops secrets.yaml`

5. **Update flake.nix** to reference your secrets repository:
   ```nix
   nix-secrets = {
     url = "git+ssh://git@github.com/YOUR_USERNAME/nix-secrets.git";
     flake = false;
   };
   ```

### Editing Secrets

```bash
cd ~/nix-secrets
sops secrets.yaml
```

### Sharing Keys Between Systems

To use the same secrets on multiple systems, copy the `id_ed25519_agenix` private key:

```bash
# Copy from source system
cp ~/.ssh/id_ed25519_agenix /path/to/secure/transfer/

# On target system
cp /path/from/secure/transfer/id_ed25519_agenix ~/.ssh/
chmod 600 ~/.ssh/id_ed25519_agenix
```

### Adding New Systems

1. Generate age public key from the new system's SSH key
2. Add it to `.sops.yaml` in the `creation_rules` section
3. Re-encrypt secrets: `sops updatekeys secrets.yaml`

## Adding a New User

1. **Update flake.nix** - Add user to `userHosts`:
   ```nix
   newuser = { 
     system = "x86_64-linux";  # or "aarch64-darwin" for Mac
     host = "hostname";
     fullName = "Full Name";
     email = "email@example.com";
   };
   ```

2. **Create user configuration**:
   ```bash
   mkdir -p users/newuser
   # Create users/newuser/default.nix with user-specific settings
   ```

3. **Create host configuration**:
   - For macOS: `hosts/darwin/hostname/`
   - For Linux: `hosts/linux/hostname/`

4. **Set up secrets**:
   - Have the new user generate their age key
   - Add their public key to `.sops.yaml`
   - Re-encrypt secrets: `sops updatekeys secrets.yaml`

## Directory Structure

```
nix/
├── flake.nix              # Main configuration with user mappings
├── hosts/
│   ├── darwin/           # macOS host configurations
│   │   └── macbook-pro/  # vwh7mb's Mac
│   └── linux/            # Linux host configurations
│       └── rjds/         # eh2889's Ubuntu server
├── users/
│   ├── vwh7mb/          # vwh7mb's configuration
│   └── eh2889/          # eh2889's configuration
├── modules/
│   ├── darwin/          # macOS-specific modules
│   ├── linux/           # Linux-specific modules
│   └── shared/          # Cross-platform modules
├── bin/                 # Helper scripts
└── overlays/            # Package overlays
```

## Common Operations

### Update System

```bash
# Update flake inputs
nix flake update

# Rebuild with updates
nix run .#build-switch
```

### Check Configuration

```bash
# Check flake
nix flake check

# Show flake info
nix flake show
```

### Garbage Collection

```bash
# Remove old generations
nix-collect-garbage -d

# Keep last 3 generations
nix-env --delete-generations +3
```

## Troubleshooting

### Permission Denied on Build

If you get permission errors on macOS:
```bash
sudo chown -R $(whoami) /nix
```

### Secrets Not Decrypting

1. Ensure age key exists: `ls ~/.ssh/id_ed25519_agenix`
2. Check key permissions: `chmod 600 ~/.ssh/id_ed25519_agenix`
3. Verify your public key is in `.sops.yaml`
4. Re-encrypt secrets: `sops updatekeys secrets.yaml`

### Build Fails

1. Check syntax: `nix flake check`
2. Review recent changes: `git diff`
3. Try building specific component: `nix build .#darwinConfigurations.vwh7mb.system`

## Security Notes

- **Never commit** private keys or unencrypted secrets
- Keep the `nix-secrets` repository **private**
- Regularly **rotate** sensitive credentials
- Use **secure methods** for transferring keys between systems

## References

- [Determinate Nix Installer](https://github.com/determinateSystems/nix-installer)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [home-manager](https://github.com/nix-community/home-manager)
- [sops-nix](https://github.com/Mic92/sops-nix)
- [Original inspiration: dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)

---

*This configuration is based on [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config), updated for compatibility with newer versions of Nix and related tools.*