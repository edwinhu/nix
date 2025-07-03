# Nix Secrets

This repository contains encrypted secrets for my nix configuration.

## Age Public Key

The secrets in this repository are encrypted with the following age key:
- `age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl`

This corresponds to the SSH key `id_ed25519_agenix` which should be present on all systems that need to decrypt these secrets.

## Usage

This repository is referenced as a flake input in the main nix configuration.

## Files

- `secrets.yaml` - Encrypted secrets (API keys, etc.)
- `.sops.yaml` - SOPS configuration with age recipients

## Security

- Keep this repository private
- Never commit unencrypted secrets
- The private key (`id_ed25519_agenix`) should never be committed