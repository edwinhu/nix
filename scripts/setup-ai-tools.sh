#!/usr/bin/env bash
# Bootstrap installer for AI CLI tools.
#
# These tools manage their own auto-updates, so nix only bundles this script
# (no nix-tracked version pins, no wrappers that fight the built-in updaters).
#
# Install all:   bash ~/nix/scripts/setup-ai-tools.sh
# Install one:   bash ~/nix/scripts/setup-ai-tools.sh claude
# Reinstall:     bash ~/nix/scripts/setup-ai-tools.sh --force claude
#
# Or via nix:    nix run ~/nix#setup-ai-tools

set -euo pipefail

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
NC=$'\033[0m'

FORCE=0
TOOLS=()
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    claude|codex|opencode|companion) TOOLS+=("$arg") ;;
    *)
      echo "${RED}Unknown argument: $arg${NC}" >&2
      exit 1
      ;;
  esac
done
if [ ${#TOOLS[@]} -eq 0 ]; then
  TOOLS=(claude codex opencode companion)
fi

# Remove stale nix-era wrappers at ~/.local/bin/<tool> that exec into /nix/store.
# Before nix stopped managing these, build-switch wrote bash wrappers like
#   #!/bin/bash
#   exec "/nix/store/.../opencode" "$@"
# These break once nix GC reaps the store path — and they make `command -v`
# falsely report the tool as installed, masking the real installer.
purge_nix_wrapper() {
  local name=$1
  local f="$HOME/.local/bin/$name"
  [ -f "$f" ] || return 0
  if grep -q '/nix/store/' "$f" 2>/dev/null; then
    echo "${YELLOW}→ Removing stale nix wrapper at $f${NC}"
    rm -f "$f"
  fi
}

# Returns 0 if install should run, 1 if already present
want() {
  local name=$1 bin=$2
  if [ "$FORCE" = "1" ]; then return 0; fi
  if command -v "$bin" >/dev/null 2>&1; then
    echo "${GREEN}✓${NC} $name already installed ($(command -v "$bin"))"
    return 1
  fi
  return 0
}

install_claude() {
  purge_nix_wrapper claude
  if ! want "claude" claude; then return 0; fi
  echo "${YELLOW}→ Installing Claude Code (native installer)...${NC}"
  curl -fsSL https://claude.ai/install.sh | bash
  echo "${GREEN}✓ Claude Code installed — it will auto-update in the background.${NC}"
}

install_codex() {
  purge_nix_wrapper codex
  if ! want "codex" codex; then return 0; fi
  local bun="$HOME/.bun/bin/bun"
  if [ ! -x "$bun" ]; then
    echo "${RED}bun not found at $bun — nix provides it; run build-switch first.${NC}" >&2
    return 1
  fi
  echo "${YELLOW}→ Installing OpenAI Codex (bun global)...${NC}"
  "$bun" install -g @openai/codex@latest
  echo "${GREEN}✓ Codex installed — update with: nix run ~/nix#update-ai-tools${NC}"
}

install_opencode() {
  purge_nix_wrapper opencode
  if ! want "opencode" opencode; then return 0; fi
  echo "${YELLOW}→ Installing OpenCode (opencode.ai installer)...${NC}"
  curl -fsSL https://opencode.ai/install | bash
  echo "${GREEN}✓ OpenCode installed — update with: opencode upgrade${NC}"
}

install_companion() {
  # the-companion lives in bun's global dir; `command -v` resolves via PATH.
  local bun="$HOME/.bun/bin/bun"
  if [ ! -x "$bun" ]; then
    echo "${RED}bun not found at $bun — nix provides it; run build-switch first.${NC}" >&2
    return 1
  fi
  if [ "$FORCE" = "0" ] && "$bun" pm ls -g 2>/dev/null | grep -q 'the-companion@'; then
    local ver
    ver=$("$bun" pm ls -g 2>/dev/null | grep -oE 'the-companion@[0-9.]+' | head -1)
    echo "${GREEN}✓${NC} $ver already installed"
    return 0
  fi
  echo "${YELLOW}→ Installing the-companion (bun global)...${NC}"
  "$bun" install -g the-companion@latest
  echo "${GREEN}✓ the-companion installed — theme + wrapper: nix run ~/nix#companion-update${NC}"
}

for t in "${TOOLS[@]}"; do
  case "$t" in
    claude)    install_claude ;;
    codex)     install_codex ;;
    opencode)  install_opencode ;;
    companion) install_companion ;;
  esac
done

echo ""
echo "${GREEN}Done.${NC} Each tool manages its own updates going forward."
