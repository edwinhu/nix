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
    claude|codex|opencode|companion|happy|happy-agent|gemini) TOOLS+=("$arg") ;;
    *)
      echo "${RED}Unknown argument: $arg${NC}" >&2
      exit 1
      ;;
  esac
done
if [ ${#TOOLS[@]} -eq 0 ]; then
  TOOLS=(claude codex opencode companion happy happy-agent gemini)
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
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if [ -L "$f" ] && [[ "$(readlink "$f")" == /nix/store/* ]]; then
    echo "${YELLOW}→ Removing stale nix symlink at $f${NC}"
    rm -f "$f"
  elif [ -f "$f" ] && grep -q '/nix/store/' "$f" 2>/dev/null; then
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

find_bun() {
  for p in "$HOME/.bun/bin/bun" "$HOME/.nix-profile/bin/bun"; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

install_codex() {
  purge_nix_wrapper codex
  if ! want "codex" codex; then return 0; fi
  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }
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
  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }
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

# happy CLI is built from the slopus/happy pnpm monorepo (mirrors
# install_happy_agent). Source-build lets us run a fork with local fixes.
# Rough edge: updates are manual — `cd ~/projects/happy && git pull && pnpm
# install && pnpm --filter happy build` (no auto-update). To track a fork
# instead of upstream: `cd ~/projects/happy && git remote set-url origin <url>`.
install_happy() {
  local repo="$HOME/projects/happy"
  local pkg="$repo/packages/happy-cli"
  local link="$HOME/.local/bin/happy"
  local mcp_link="$HOME/.local/bin/happy-mcp"
  local bin="$pkg/bin/happy.mjs"
  local mcp_bin="$pkg/bin/happy-mcp.mjs"

  # Drop any stale installs so `command -v happy` reflects ours.
  purge_nix_wrapper happy
  purge_nix_wrapper happy-mcp
  if [ -e "$HOME/.local/share/lib/node_modules/happy" ] || \
     [ -e "$HOME/.local/share/bin/happy" ]; then
    echo "${YELLOW}→ Removing npm-installed happy (replaced by from-source build)${NC}"
    npm uninstall -g happy >/dev/null 2>&1 || true
  fi
  for L in "$link" "$mcp_link"; do
    target_bin="$bin"; [ "$L" = "$mcp_link" ] && target_bin="$mcp_bin"
    if [ -L "$L" ] && [ "$(readlink "$L")" != "$target_bin" ]; then
      rm -f "$L"
    fi
  done

  if [ "$FORCE" = "0" ] && [ -L "$link" ] && [ -L "$mcp_link" ] && [ -f "$pkg/dist/index.mjs" ]; then
    echo "${GREEN}✓${NC} happy already installed (from $pkg)"
    return 0
  fi

  if [ ! -d "$repo/.git" ]; then
    echo "${YELLOW}→ Cloning slopus/happy → $repo${NC}"
    mkdir -p "$(dirname "$repo")"
    git clone https://github.com/slopus/happy.git "$repo"
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    echo "${YELLOW}→ Installing pnpm (npm global)${NC}"
    npm i -g pnpm
  fi

  echo "${YELLOW}→ Building happy from monorepo${NC}"
  ( cd "$repo" && pnpm install )
  ( cd "$repo" && pnpm --filter happy build )

  mkdir -p "$HOME/.local/bin"
  ln -sf "$bin" "$link"
  ln -sf "$mcp_bin" "$mcp_link"

  # Bootstrap ~/.happy/settings.json from dotfiles template if missing.
  # Can't stow this file: happy uses atomic write (writeFile temp + rename),
  # which clobbers a symlink with a regular file on first save. Instead, merge
  # template (sandboxConfig + schemaVersion) into live settings, preserving
  # per-machine fields like machineId / onboardingCompleted.
  local tmpl="$HOME/dotfiles/.happy/settings.template.json"
  local live="$HOME/.happy/settings.json"
  if [ -f "$tmpl" ] && command -v jq >/dev/null 2>&1; then
    mkdir -p "$HOME/.happy"
    if [ -f "$live" ]; then
      tmp="$(mktemp)"
      jq -s '.[0] * .[1]' "$live" "$tmpl" > "$tmp" && mv "$tmp" "$live"
      echo "${GREEN}✓ happy settings: merged template into $live (machineId preserved)${NC}"
    else
      cp "$tmpl" "$live"
      echo "${GREEN}✓ happy settings: bootstrapped from template (machineId will be generated on first run)${NC}"
    fi
  fi

  echo "${GREEN}✓ happy installed (symlinked from $pkg)${NC}"
  echo "${YELLOW}  Authenticate with: happy auth login${NC}"
  echo "${YELLOW}  Updates: cd $repo && git pull && pnpm install && pnpm --filter happy build${NC}"
}

# happy-agent is part of the slopus/happy pnpm monorepo. We build from source
# rather than installing the published npm package because (a) the agent is
# evolving fast and the monorepo carries unreleased fixes, (b) building locally
# keeps it pinned to whatever HEAD the user has cloned. Rough edge: updates are
# manual — `cd ~/projects/happy && git pull && pnpm install && pnpm --filter
# happy-agent build` (no auto-update).
install_happy_agent() {
  local repo="$HOME/projects/happy"
  local pkg="$repo/packages/happy-agent"
  local bin="$pkg/bin/happy-agent.mjs"
  local link="$HOME/.local/bin/happy-agent"

  # Drop any stale installs so `command -v happy-agent` reflects ours.
  purge_nix_wrapper happy-agent
  if [ -e "$HOME/.local/share/lib/node_modules/happy-agent" ] || \
     [ -e "$HOME/.local/share/bin/happy-agent" ]; then
    echo "${YELLOW}→ Removing npm-installed happy-agent (replaced by from-source build)${NC}"
    npm uninstall -g happy-agent >/dev/null 2>&1 || true
  fi
  if [ -L "$link" ] && [ "$(readlink "$link")" != "$bin" ]; then
    rm -f "$link"
  fi

  if [ "$FORCE" = "0" ] && [ -L "$link" ] && [ -f "$pkg/dist/index.cjs" ]; then
    echo "${GREEN}✓${NC} happy-agent already installed (from $pkg)"
    return 0
  fi

  if [ ! -d "$repo/.git" ]; then
    echo "${YELLOW}→ Cloning slopus/happy → $repo${NC}"
    mkdir -p "$(dirname "$repo")"
    git clone https://github.com/slopus/happy.git "$repo"
  fi

  # pnpm needs to be on PATH (the monorepo's postinstall shells out to `pnpm`
  # directly, so `corepack pnpm` isn't enough — the child process wouldn't find
  # it). Install via npm global if missing; lands at ~/.local/share/bin/pnpm
  # and stays on PATH alongside happy-agent itself.
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "${YELLOW}→ Installing pnpm (npm global)${NC}"
    npm i -g pnpm
  fi

  echo "${YELLOW}→ Building happy-agent from monorepo${NC}"
  ( cd "$repo" && pnpm install )
  ( cd "$repo" && pnpm --filter happy-agent build )

  mkdir -p "$HOME/.local/bin"
  ln -sf "$bin" "$link"

  echo "${GREEN}✓ happy-agent installed (symlinked from $pkg)${NC}"
  echo "${YELLOW}  Updates: cd $repo && git pull && pnpm install && pnpm --filter happy-agent build${NC}"
}

install_gemini() {
  purge_nix_wrapper gemini
  if ! want "gemini" gemini; then return 0; fi
  echo "${YELLOW}→ Installing Gemini CLI (npm global)...${NC}"
  npm i -g @google/gemini-cli
  echo "${GREEN}✓ Gemini CLI installed${NC}"
}

for t in "${TOOLS[@]}"; do
  case "$t" in
    claude)       install_claude ;;
    codex)        install_codex ;;
    opencode)     install_opencode ;;
    companion)    install_companion ;;
    happy)        install_happy ;;
    happy-agent)  install_happy_agent ;;
    gemini)       install_gemini ;;
  esac
done

echo ""
echo "${GREEN}Done.${NC} Each tool manages its own updates going forward."
