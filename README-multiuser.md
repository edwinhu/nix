# Multi-User, Multi-Platform Nix Configuration

This nix configuration now supports multiple users across different platforms.

## Current Users and Hosts

- **vwh7mb** on **macbook-pro** (macOS/Darwin, aarch64)
- **eh2889** on **rjds** (Ubuntu Linux, x86_64)

## Usage

### For macOS (nix-darwin)

```bash
# Build and switch for vwh7mb
darwin-rebuild switch --flake .#vwh7mb

# Or use the nix run command
nix run .#darwinConfigurations.vwh7mb.system.build.switch
```

### For Linux (home-manager standalone)

```bash
# Build and switch for eh2889
home-manager switch --flake .#eh2889

# Or use nix run
nix run .#homeConfigurations.eh2889.activationPackage
```

## Adding a New User

1. Add the user to `userHosts` in `flake.nix`:
   ```nix
   newuser = { 
     system = "x86_64-linux";  # or "aarch64-darwin" for Mac
     host = "hostname";
     fullName = "Full Name";
     email = "email@example.com";
   };
   ```

2. Create user-specific configuration in `users/newuser/default.nix`

3. Create host configuration in:
   - `hosts/darwin/hostname/` for macOS
   - `hosts/linux/hostname/` for Linux

## Secrets Management

Each user needs to:

1. Generate an age key:
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

2. Add their public key to `.sops.yaml`

3. Re-encrypt secrets:
   ```bash
   sops updatekeys secrets.yaml
   ```

## Directory Structure

```
nix/
├── flake.nix              # Main configuration with userHosts mapping
├── hosts/
│   ├── darwin/           # macOS hosts
│   │   └── macbook-pro/  # vwh7mb's Mac
│   └── linux/            # Linux hosts
│       └── rjds/         # eh2889's Ubuntu server
├── users/
│   ├── vwh7mb/          # vwh7mb's personal config
│   └── eh2889/          # eh2889's personal config
└── modules/
    ├── darwin/          # macOS-specific modules
    ├── linux/           # Linux-specific modules
    └── shared/          # Cross-platform modules
```