# Setting up nix-secrets Repository

This guide explains how to set up the private secrets repository for your nix configuration.

## Prerequisites

1. GitHub CLI installed and authenticated:
   ```bash
   gh auth login
   ```

2. The `id_ed25519_agenix` key generated in `~/.ssh/`

## Steps

### 1. Create the Private Repository

```bash
gh repo create nix-secrets --private --description "Encrypted secrets for nix configuration"
```

### 2. Clone the Repository

```bash
cd ~/
git clone git@github.com:YOUR_USERNAME/nix-secrets.git
cd nix-secrets
```

### 3. Move Secrets Files

```bash
# Copy the secrets files from the main nix repo
cp ~/nix/secrets.yaml .
cp ~/nix/.sops.yaml .
```

### 4. Create README for the secrets repo

```bash
cat > README.md << 'EOF'
# Nix Secrets

This repository contains encrypted secrets for my nix configuration.

## Age Public Key

The secrets in this repository are encrypted with the following age key:
- `age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl`

This corresponds to the SSH key `id_ed25519_agenix` which should be present on all systems that need to decrypt these secrets.

## Usage

This repository is referenced as a flake input in the main nix configuration.
EOF
```

### 5. Commit and Push

```bash
git add .
git commit -m "Initial secrets setup"
git push -u origin main
```

### 6. Update Main Nix Flake

After setting up the secrets repository, update your main nix flake to reference it:

```nix
inputs = {
  # ... other inputs ...
  nix-secrets = {
    url = "git+ssh://git@github.com/YOUR_USERNAME/nix-secrets.git";
    flake = false;
  };
};
```

### 7. Update secrets.nix Module

Update the secrets module to reference the nix-secrets input:

```nix
{ config, pkgs, user, self, nix-secrets, ... }:

{
  sops.defaultSopsFile = "${nix-secrets}/secrets.yaml";
  # ... rest of config ...
}
```

## Key Management

### Sharing Keys Between Systems

To use the same secrets on multiple systems:

1. Copy the `id_ed25519_agenix` private key to your other systems
2. Use the `copy-keys` script with a USB drive, or
3. Use a secure transfer method of your choice

### Adding New Systems

If you need to add a new system with a different age key:

1. Generate the age public key from the SSH key
2. Add it to `.sops.yaml` in the creation_rules
3. Re-encrypt the secrets: `sops updatekeys secrets.yaml`

## Security Notes

- Never commit the private key (`id_ed25519_agenix`) to any repository
- Keep the nix-secrets repository private
- Regularly rotate sensitive secrets