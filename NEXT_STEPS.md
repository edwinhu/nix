# Next Steps to Complete the Migration

## 1. Clone and Set Up the nix-secrets Repository

In your terminal where GitHub CLI is authenticated:

```bash
# Clone your nix-secrets repository
cd ~/
git clone git@github.com:eddyhu/nix-secrets.git

# Copy the prepared files
cp ~/nix/nix-secrets-files/* ~/nix-secrets/

# Commit and push
cd ~/nix-secrets
git add .
git commit -m "Initial secrets setup with new age key"
git push -u origin main
```

## 2. Add Your API Keys

Edit the secrets file to add your actual API keys:

```bash
cd ~/nix
nix-shell -p sops --run "SOPS_AGE_KEY_FILE=~/.ssh/id_ed25519_agenix sops ~/nix-secrets/secrets.yaml"
```

This will open an editor where you can replace the empty strings with your actual API keys:
- GOOGLE_SEARCH_API_KEY
- GOOGLE_SEARCH_ENGINE_ID  
- GEMINI_API_KEY
- CLAUDE_API_KEY

Save and exit the editor when done.

## 3. Commit the Updated Secrets

```bash
cd ~/nix-secrets
git add secrets.yaml
git commit -m "Add API keys"
git push
```

## 4. Test the Configuration

```bash
cd ~/nix
nix run .#build-switch
```

## 5. Share Keys with macOS System

To use the same secrets on your macOS system, copy the `id_ed25519_agenix` key:

```bash
# On Linux, copy to USB or use secure transfer method
# The key is at: ~/.ssh/id_ed25519_agenix

# On macOS, place it at:
# /Users/YOUR_USERNAME/.ssh/id_ed25519_agenix
```

## Summary of Changes Made

1. ✅ Created Linux key management scripts
2. ✅ Updated flake.nix to include nix-secrets input
3. ✅ Updated secrets.nix to use SSH key for decryption
4. ✅ Re-enabled sops-nix in Linux configuration
5. ✅ Created new secrets.yaml encrypted with your age key

Your age public key for reference:
`age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl`