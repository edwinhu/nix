# Secrets Migration Summary

## What We've Done

1. **Fixed the Nix evaluation warning**: Changed `./../../secrets.yaml` to `"${self}/secrets.yaml"` in `modules/shared/secrets.nix`

2. **Created Linux key management scripts**:
   - `/apps/x86_64-linux/create-keys` - Creates SSH keys including `id_ed25519_agenix`
   - `/apps/x86_64-linux/copy-keys` - Copies keys from USB drive
   - `/apps/x86_64-linux/check-keys` - Verifies key installation
   - `/apps/x86_64-linux/install` - Basic installation script
   - `/apps/x86_64-linux/install-with-secrets` - Installation with secrets verification

3. **Generated shared age key**:
   - Created `id_ed25519_agenix` SSH key
   - Age public key: `age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl`
   - Updated `.sops.yaml` with this new key

4. **Temporarily disabled sops-nix** in `hosts/linux/rjds/default.nix` to prevent service failures

## Next Steps

### 1. Create Private GitHub Repository

```bash
gh auth login  # If not already authenticated
gh repo create nix-secrets --private --description "Encrypted secrets for nix configuration"
```

### 2. Set Up the Secrets Repository

```bash
cd ~/
git clone git@github.com:YOUR_USERNAME/nix-secrets.git
cd nix-secrets

# Copy secrets files
cp ~/nix/secrets.yaml .
cp ~/nix/.sops.yaml .

# Create README
echo "# Nix Secrets" > README.md
echo "Private repository for encrypted nix configuration secrets" >> README.md

# Commit and push
git add .
git commit -m "Initial secrets setup"
git push -u origin main
```

### 3. Re-encrypt Secrets with New Key

Run the re-encryption script we created:
```bash
cd ~/nix
./reencrypt-secrets.sh
```

Then copy the updated secrets.yaml to your nix-secrets repo:
```bash
cp secrets.yaml ~/nix-secrets/
cd ~/nix-secrets
git add secrets.yaml
git commit -m "Re-encrypt with new age key"
git push
```

### 4. Update Main Flake

Add the nix-secrets input to your `flake.nix`:

```nix
inputs = {
  # ... existing inputs ...
  nix-secrets = {
    url = "git+ssh://git@github.com/YOUR_USERNAME/nix-secrets.git";
    flake = false;
  };
};
```

Update the outputs function signature:
```nix
outputs = { self, darwin, emacsmacport, nix-homebrew, homebrew-bundle, homebrew-core, homebrew-cask, home-manager, nixpkgs, stylix, sops-nix, nix-secrets } @inputs:
```

### 5. Update secrets.nix Module

Replace the current `modules/shared/secrets.nix` with the version in `secrets-updated.nix` that uses the nix-secrets input.

### 6. Re-enable sops-nix

Uncomment the secrets.nix import in `hosts/linux/rjds/default.nix`:
```nix
imports = [
  ../../../modules/linux/home-manager.nix
  ../../../modules/shared/secrets.nix  # Re-enable this line
];
```

### 7. Test the Configuration

```bash
nix run .#build-switch
```

## Key Distribution

To use the same secrets on your macOS system:

1. Copy the `id_ed25519_agenix` private key to your Mac:
   - Use the `copy-keys` script with a USB drive, or
   - Use secure file transfer

2. Ensure the key is in the correct location:
   - Linux: `/home/USERNAME/.ssh/id_ed25519_agenix`
   - macOS: `/Users/USERNAME/.ssh/id_ed25519_agenix`

## Important Notes

- The deprecated 'install' alias warning is from home-manager's internal code and can be ignored
- Keep your `id_ed25519_agenix` private key secure and never commit it to any repository
- The age public key (`age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl`) can be shared publicly

## Files Created/Modified

- Created: Linux key management scripts in `/apps/x86_64-linux/`
- Modified: `/modules/shared/secrets.nix` (fixed evaluation warning)
- Modified: `/.sops.yaml` (updated with new age key)
- Modified: `/hosts/linux/rjds/default.nix` (temporarily disabled sops)
- Created: `/secrets-setup.md` (detailed setup guide)
- Created: `/flake-update-template.nix` (template for flake updates)
- Created: `/modules/shared/secrets-updated.nix` (updated secrets module)
- Created: `/reencrypt-secrets.sh` (re-encryption helper script)