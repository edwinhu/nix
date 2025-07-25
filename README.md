# Multi-User, Multi-Platform Nix Configuration

A comprehensive Nix configuration supporting multiple users across macOS and Linux platforms, featuring [Determinate Nix 3.0](https://github.com/determinateSystems/nix-installer), [home-manager](https://github.com/nix-community/home-manager), [nix-darwin](https://github.com/LnL7/nix-darwin), and secure secrets management with [agenix](https://github.com/ryantm/agenix).

## Features

- **Multi-user support**: Each user has independent configuration with personal settings, packages, and secrets
- **Multi-platform**: Full support for macOS (via nix-darwin) and Linux (via standalone home-manager)
- **Secure secrets**: Encrypted secrets management using agenix
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

This configuration uses agenix with SSH key encryption for managing secrets like API keys.

### Initial Setup

1. **Generate SSH key** (if not already done):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
   ```
   Note: The key can be named `id_ed25519` or `id_ed25519_agenix` - both will work.

2. **Get your age public key** (for reference):
   ```bash
   nix-shell -p ssh-to-age --run "ssh-to-age < ~/.ssh/id_ed25519.pub"
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

4. **Configure secrets.nix**:
   - Create a `secrets.nix` file listing your SSH public key
   - Add entries for each secret file
   - See the nix-secrets README for the exact format

5. **Update flake.nix** to reference your secrets repository:
   ```nix
   nix-secrets = {
     url = "git+ssh://git@github.com/YOUR_USERNAME/nix-secrets.git";
     flake = false;
   };
   ```

### Adding New Secrets

1. **Create the encrypted secret file**:
   ```bash
   cd ~/nix-secrets
   nix run github:ryantm/agenix -- -e newsecret.age
   ```

2. **Update TWO configuration files**:
   
   a. In `~/nix-secrets/secrets.nix`:
   ```nix
   "newsecret.age".publicKeys = users ++ systems;
   ```
   
   b. In `~/nix/modules/shared/home-secrets.nix`:
   ```nix
   # Add to age.secrets block
   newsecret = {
     file = "${nix-secrets}/newsecret.age";
     mode = "400";
   };
   
   # Add to home.sessionVariables if needed as environment variable
   NEWSECRET_VAR = "$(cat ${config.age.secrets.newsecret.path})";
   ```

3. **Commit and push changes**:
   ```bash
   # In nix-secrets repo
   cd ~/nix-secrets
   git add newsecret.age secrets.nix
   git commit -m "Add newsecret"
   git push
   
   # In nix repo
   cd ~/nix
   git add modules/shared/home-secrets.nix
   git commit -m "Add newsecret configuration"
   git push
   ```

4. **Update and rebuild**:
   ```bash
   cd ~/nix
   nix flake update nix-secrets
   nix run .#build-switch
   ```

### Editing Existing Secrets

```bash
cd ~/nix-secrets
nix run github:ryantm/agenix -- -e secret-name.age
```

### Sharing Keys Between Systems

To use the same secrets on multiple systems, copy the SSH private key:

```bash
# Copy from source system
cp ~/.ssh/id_ed25519 /path/to/secure/transfer/

# On target system
cp /path/from/secure/transfer/id_ed25519 ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
```

### Adding New Systems

1. Generate SSH key on the new system
2. Get the age public key: `nix-shell -p ssh-to-age --run "ssh-to-age < ~/.ssh/id_ed25519.pub"`
3. Add the SSH public key to `~/nix-secrets/secrets.nix` in the users or systems list
4. Re-encrypt all secrets: `cd ~/nix-secrets && nix run github:ryantm/agenix -- -r`

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

2. **Add user to flake.nix**:
   - Add user info to the `userInfo` attribute set in `flake.nix`
   - Map the user to their host in the `userHosts` attribute

3. **Create host configuration**:
   - For macOS: `hosts/darwin/hostname/`
   - For Linux: `hosts/linux/hostname/`

4. **Set up secrets**:
   - Have the new user generate their SSH key: `ssh-keygen -t ed25519`
   - Get their age public key: `nix-shell -p ssh-to-age --run "ssh-to-age < ~/.ssh/id_ed25519.pub"`
   - Add their SSH public key to `~/nix-secrets/secrets.nix`
   - Re-encrypt secrets: `cd ~/nix-secrets && nix run github:ryantm/agenix -- -r`

## Directory Structure

```
nix/
├── flake.nix              # Main configuration with user mappings
├── hosts/
│   ├── darwin/           # macOS host configurations
│   │   └── macbook-pro/  # vwh7mb's Mac
│   └── linux/            # Linux host configurations
│       └── rjds/         # eh2889's Ubuntu server
├── users/                # (Directory can be removed if empty)
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
3. Verify your public key is in the nix-secrets repository
4. Update the secrets input: `nix flake update nix-secrets`

### Build Fails

1. Check syntax: `nix flake check`
2. Review recent changes: `git diff`
3. Try building specific component: `nix build .#darwinConfigurations.vwh7mb.system`

## Security Notes

- **Never commit** private keys or unencrypted secrets
- Keep the `nix-secrets` repository **private**
- Regularly **rotate** sensitive credentials
- Use **secure methods** for transferring keys between systems

## Troubleshooting Secrets

### Secret not appearing or environment variable not set

If your secret exists in nix-secrets but doesn't work:

1. **Ensure you updated the configuration file**:
   - `modules/shared/home-secrets.nix` - This is the ONLY place secrets are configured
   - Add to both `age.secrets` block and `home.sessionVariables` if you need it as an environment variable

2. **Update the flake input**:
   ```bash
   nix flake update nix-secrets
   ```

3. **Check all changes are committed** in both repos

4. **Rebuild**: `nix run .#build-switch`

### Common Secret Issues

- **Decryption fails**: Ensure your SSH key (`id_ed25519_agenix`) matches what's in `nix-secrets/secrets.nix`
- **Environment variable empty**: Start a new shell after rebuild or source `~/.nix-profile/etc/profile.d/hm-session-vars.sh`
- **Build errors**: Check that the `.age` file exists in nix-secrets
- **Wrong agenix command**: Use `nix run github:ryantm/agenix --` not just `agenix`
- **macOS location**: Secrets are decrypted to `$(getconf DARWIN_USER_TEMP_DIR)/agenix/` not `/run/agenix/`

## References

- [Determinate Nix Installer](https://github.com/determinateSystems/nix-installer)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [home-manager](https://github.com/nix-community/home-manager)
- [agenix](https://github.com/ryantm/agenix)
- [Original inspiration: dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)

---

*This configuration is based on [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config), updated for compatibility with newer versions of Nix and related tools.*