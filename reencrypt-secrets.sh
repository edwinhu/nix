#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Re-encrypting secrets with new age key...${NC}"

# Check if sops is installed
if ! command -v sops &> /dev/null; then
    echo -e "${RED}sops is not installed. Install it with: nix-shell -p sops${NC}"
    exit 1
fi

# Check if the agenix SSH key exists
if [[ ! -f "$HOME/.ssh/id_ed25519_agenix" ]]; then
    echo -e "${RED}Missing id_ed25519_agenix key. Run: nix run .#create-keys${NC}"
    exit 1
fi

# Convert SSH key to age key and create temporary age key file
echo -e "${YELLOW}Converting SSH key to age format...${NC}"
SSH_TO_AGE_OUTPUT=$(nix-shell -p ssh-to-age --run "ssh-to-age -private-key < $HOME/.ssh/id_ed25519_agenix" 2>/dev/null)
TEMP_AGE_KEY=$(mktemp)
echo "$SSH_TO_AGE_OUTPUT" > "$TEMP_AGE_KEY"

# Set SOPS_AGE_KEY_FILE for this session
export SOPS_AGE_KEY_FILE="$TEMP_AGE_KEY"

# Update the keys in secrets.yaml
echo -e "${YELLOW}Updating encryption keys in secrets.yaml...${NC}"
if sops updatekeys secrets.yaml; then
    echo -e "${GREEN}Successfully re-encrypted secrets.yaml with new key!${NC}"
else
    echo -e "${RED}Failed to re-encrypt secrets.yaml${NC}"
    rm -f "$TEMP_AGE_KEY"
    exit 1
fi

# Clean up
rm -f "$TEMP_AGE_KEY"

echo -e "${GREEN}Re-encryption complete!${NC}"
echo -e "${YELLOW}Note: Make sure to update both .sops.yaml and secrets.yaml in your private nix-secrets repository.${NC}"