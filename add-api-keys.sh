#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}This script will help you add API keys to your secrets file.${NC}"
echo -e "${YELLOW}Leave blank to skip any key.${NC}\n"

# Function to safely read sensitive input
read_secret() {
    local prompt="$1"
    local var_name="$2"
    echo -n "$prompt"
    read -s -r "$var_name"
    echo
}

# Read API keys
read_secret "Enter GOOGLE_SEARCH_API_KEY: " GOOGLE_KEY
read_secret "Enter GOOGLE_SEARCH_ENGINE_ID: " GOOGLE_ENGINE
read_secret "Enter GEMINI_API_KEY: " GEMINI_KEY
read_secret "Enter CLAUDE_API_KEY: " CLAUDE_KEY

# Create temporary file with the values
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" << EOF
GOOGLE_SEARCH_API_KEY: "${GOOGLE_KEY}"
GOOGLE_SEARCH_ENGINE_ID: "${GOOGLE_ENGINE}"
GEMINI_API_KEY: "${GEMINI_KEY}"
CLAUDE_API_KEY: "${CLAUDE_KEY}"
EOF

# Encrypt with sops
echo -e "\n${YELLOW}Encrypting secrets...${NC}"
if nix-shell -p sops --run "sops -e --age age1ny7ddm7ka9dt54wgmssx0klpfl4stjecdedm4tpk5c8sv95uwdlqsfklpl $TEMP_FILE > ~/nix-secrets/secrets.yaml"; then
    echo -e "${GREEN}Successfully updated secrets.yaml${NC}"
    
    # Commit changes
    echo -e "\n${YELLOW}Committing changes...${NC}"
    (cd ~/nix-secrets && git add secrets.yaml && git commit -m "Add API keys" && git push)
    echo -e "${GREEN}Changes pushed to repository!${NC}"
else
    echo -e "${RED}Failed to encrypt secrets${NC}"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Clean up
rm -f "$TEMP_FILE"

echo -e "\n${GREEN}API keys successfully added and pushed!${NC}"