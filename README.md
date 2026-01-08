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
- **edwinhu** on **alarm** (Arch Linux/Asahi, aarch64)

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

This configuration uses [agenix](https://github.com/ryantm/agenix) with SSH key encryption for managing secrets like API keys. Secrets are stored encrypted in a private `nix-secrets` repo and decrypted at runtime.

### How It Works

1. **One SSH key** (`~/.ssh/id_ed25519_agenix`) is used across ALL systems
2. **Secrets are encrypted** in `~/nix-secrets/*.age` files using that key's public key
3. **On activation**, home-manager's agenix module decrypts secrets to:
   - macOS: `$(getconf DARWIN_USER_TEMP_DIR)/agenix/`
   - Linux: `$XDG_RUNTIME_DIR/agenix/`
4. **Environment variables** (e.g., `$READWISE_TOKEN_FILE`) point to decrypted file paths

### Key Files

| File | Purpose |
|------|---------|
| `~/.ssh/id_ed25519_agenix` | Private key for decryption (same on all systems) |
| `~/nix-secrets/secrets.nix` | Lists which public keys can decrypt which secrets |
| `~/nix-secrets/*.age` | Encrypted secret files |
| `~/nix/modules/shared/home-secrets.nix` | Configures which secrets to decrypt and env vars |

### Initial Setup (New Installation)

#### 1. Set up the agenix key

**Option A: Copy existing key from another system** (recommended)
```bash
# From a system that already has secrets working
scp ~/.ssh/id_ed25519_agenix newhost:~/.ssh/id_ed25519_agenix
ssh newhost "chmod 600 ~/.ssh/id_ed25519_agenix"
```

**Option B: Create new key** (only if starting fresh)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_agenix -N ""
# Then add the public key to nix-secrets/secrets.nix and re-encrypt
```

#### 2. Clone the secrets repo

```bash
cd ~/
git clone git@github.com:edwinhu/nix-secrets.git
```

#### 3. Ensure host config imports home-secrets

In `hosts/linux/<hostname>/default.nix` or `hosts/darwin/<hostname>/default.nix`:
```nix
{
  imports = [
    ../../../modules/shared/home-secrets.nix
  ];
  # ... rest of config
}
```

#### 4. Build and switch

```bash
cd ~/nix
nix run .#build-switch
```

#### 5. Verify secrets work

```bash
# Start new shell, then:
echo $READWISE_TOKEN_FILE
cat $READWISE_TOKEN_FILE
```

### Adding New Secrets

1. **Create encrypted secret file**:
   ```bash
   cd ~/nix-secrets
   nix run github:ryantm/agenix -- -e newsecret.age
   # Editor opens - paste secret value, save, exit
   ```

2. **Register in secrets.nix** (in nix-secrets repo):
   ```nix
   "newsecret.age".publicKeys = users ++ systems;
   ```

3. **Configure in home-secrets.nix** (in nix repo):
   ```nix
   # In age.secrets block:
   newsecret = {
     file = "${nix-secrets}/newsecret.age";
     mode = "400";
   };
   
   # In home.sessionVariables block (to expose as env var):
   NEWSECRET_FILE = "${tempDir}/newsecret";
   ```

4. **Commit both repos and rebuild**:
   ```bash
   # nix-secrets
   cd ~/nix-secrets && git add -A && git commit -m "Add newsecret" && git push
   
   # nix
   cd ~/nix && git add -A && git commit -m "Add newsecret config" && git push
   nix flake update nix-secrets
   nix run .#build-switch
   ```

### Editing Existing Secrets

```bash
cd ~/nix-secrets
nix run github:ryantm/agenix -- -e secret-name.age
git add secret-name.age && git commit -m "Update secret-name" && git push

cd ~/nix
nix flake update nix-secrets
nix run .#build-switch
```

### Adding a New System (Using Existing Key)

The simple approach - copy the existing agenix key:

```bash
# From working system to new system
scp ~/.ssh/id_ed25519_agenix newhost:~/.ssh/id_ed25519_agenix
ssh newhost "chmod 600 ~/.ssh/id_ed25519_agenix"
```

Then build on the new system - no changes to nix-secrets needed.

### Adding a New System (With New Key)

If you want the new system to have its own key:

1. **Generate key on new system**:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_agenix -N ""
   ```

2. **Add public key to nix-secrets/secrets.nix**:
   ```nix
   let
     existingKey = "ssh-ed25519 AAAA... user@host1";
     newKey = "ssh-ed25519 AAAA... user@newhost";
     users = [ existingKey newKey ];
   in { ... }
   ```

3. **Re-encrypt all secrets**:
   ```bash
   cd ~/nix-secrets
   nix run github:ryantm/agenix -- -r
   git add -A && git commit -m "Add newhost key" && git push
   ```

4. **Update and rebuild on all systems**:
   ```bash
   cd ~/nix
   nix flake update nix-secrets
   nix run .#build-switch
   ```

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

### Checklist

1. **Key exists**: `ls -la ~/.ssh/id_ed25519_agenix`
2. **Key permissions**: `chmod 600 ~/.ssh/id_ed25519_agenix`
3. **Key matches nix-secrets**: Public key in `~/nix-secrets/secrets.nix` must match your private key
4. **home-secrets.nix imported**: Host config must have `imports = [ ../../../modules/shared/home-secrets.nix ];`
5. **Flake updated**: `nix flake update nix-secrets`
6. **Rebuilt**: `nix run .#build-switch`
7. **New shell**: Start fresh shell after rebuild

### Common Issues

| Problem | Solution |
|---------|----------|
| `READWISE_TOKEN_FILE` is empty | Start a new shell after rebuild |
| Decryption fails | Key mismatch - copy working key from another system |
| No agenix directory | home-secrets.nix not imported in host config |
| `agenix` command not found | Use `nix run github:ryantm/agenix --` |
| Secrets not updating | Run `nix flake update nix-secrets` before rebuild |

### Where Are Secrets Decrypted?

- **macOS**: `$(getconf DARWIN_USER_TEMP_DIR)/agenix/` (e.g., `/var/folders/.../T/agenix/`)
- **Linux**: `$XDG_RUNTIME_DIR/agenix/` (e.g., `/run/user/1000/agenix/`)

### Debug Commands

```bash
# Check if agenix service ran (Linux)
systemctl --user status agenix.service

# Check decrypted secrets exist
ls -la $XDG_RUNTIME_DIR/agenix/        # Linux
ls -la $(getconf DARWIN_USER_TEMP_DIR)/agenix/  # macOS

# Check env var is set
echo $READWISE_TOKEN_FILE

# Read secret value
cat $READWISE_TOKEN_FILE
```

## References

- [Determinate Nix Installer](https://github.com/determinateSystems/nix-installer)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [home-manager](https://github.com/nix-community/home-manager)
- [agenix](https://github.com/ryantm/agenix)
- [Original inspiration: dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)

---

*This configuration is based on [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config), updated for compatibility with newer versions of Nix and related tools.*