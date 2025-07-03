#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Creating fresh secrets.yaml with new age key...${NC}"

# Create a temporary age key from the SSH key
AGE_KEY=$(nix-shell -p ssh-to-age --run "ssh-to-age -private-key < ~/.ssh/id_ed25519_agenix" 2>/dev/null)
export SOPS_AGE_KEY="$AGE_KEY"

# Create new secrets.yaml
cat > secrets-new.yaml << 'EOF'
GOOGLE_SEARCH_API_KEY: ""
GOOGLE_SEARCH_ENGINE_ID: ""
GEMINI_API_KEY: ""
CLAUDE_API_KEY: ""
EOF

# Encrypt the new file
echo -e "${YELLOW}Encrypting new secrets file...${NC}"
nix-shell -p sops --run "sops -e --age age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl secrets-new.yaml > secrets.yaml.new"

if [ -f secrets.yaml.new ]; then
    echo -e "${GREEN}Successfully created new encrypted secrets.yaml${NC}"
    echo -e "${YELLOW}The file is at: secrets.yaml.new${NC}"
    echo -e "${YELLOW}You'll need to edit it to add your actual API keys:${NC}"
    echo "  nix-shell -p sops --run \"SOPS_AGE_KEY='$AGE_KEY' sops secrets.yaml.new\""
else
    echo -e "${RED}Failed to create new secrets file${NC}"
    exit 1
fi