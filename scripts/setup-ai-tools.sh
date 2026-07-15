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
    claude|codex|opencode|gemini|agy|qmd|readwise) TOOLS+=("$arg") ;;
    *)
      echo "${RED}Unknown argument: $arg${NC}" >&2
      exit 1
      ;;
  esac
done
if [ ${#TOOLS[@]} -eq 0 ]; then
  TOOLS=(claude codex opencode agy qmd readwise)
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

# qmd (tobi/qmd) — "Quick Markdown Search", a local BM25+vector search engine
# over the Obsidian vault. Secondary retrieval + compile-time discovery aid for
# the knowledge base (see ~/notes/.claude/CLAUDE.md; wired in ~/notes/scripts/
# qmd.py). Installed as a bun global like codex, then the vault collection is
# bootstrapped idempotently. Embeddings are NOT built here (slow, downloads a
# local GGUF model) — the nightly vault-compile's reindex step handles that;
# until then hybrid queries fall back to BM25.
install_qmd() {
  purge_nix_wrapper qmd
  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }
  if want "qmd" qmd; then
    echo "${YELLOW}→ Installing qmd (bun global)...${NC}"
    "$bun" install -g @tobilu/qmd@latest
    echo "${GREEN}✓ qmd installed — update with: nix run ~/nix#update-ai-tools${NC}"
  fi
  # Bootstrap the vault collection if the vault exists and isn't indexed yet.
  local qmd_bin
  qmd_bin=$(command -v qmd 2>/dev/null || echo "$HOME/.bun/bin/qmd")
  if [ -x "$qmd_bin" ] && [ -d "$HOME/notes" ]; then
    if ! "$qmd_bin" collection list 2>/dev/null | grep -q '\bnotes\b'; then
      echo "${YELLOW}→ Bootstrapping qmd 'notes' collection over ~/notes${NC}"
      "$qmd_bin" collection add "$HOME/notes" --name notes || true
      echo "${GREEN}✓ qmd 'notes' collection added — vectors build on next vault-compile (or run 'qmd embed').${NC}"
    fi
  fi
}

# Readwise — TWO separate CLIs the `readwise`/librarian skill depends on:
#   readwise         official @readwise/cli (bun global). Provides semantic /
#                    vector highlight search:
#                      readwise readwise-search-highlights --vector-search-term …
#                    Its absence is what silently degrades the librarian to
#                    keyword-only raw-API calls (no semantic ranking).
#   readwise-custom  our own edwinhu/readwise-cli — a bun `--compile` single-file
#                    binary (RAG chat, keyword search, upload, prune, ghostreader).
# Auth needs no new secret: both resolve the token from the agenix-provided
# $READWISE_TOKEN env var. The official CLI also caches a login, which we set
# idempotently whenever a token is present. Mirrors the mbp layout
# (~/.bun/bin/readwise + ~/.local/bin/readwise-custom -> ~/projects/readwise-cli).
install_readwise() {
  purge_nix_wrapper readwise
  purge_nix_wrapper readwise-custom
  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }

  # 1) Official @readwise/cli (bun global) -> `readwise`.
  if want "readwise (@readwise/cli)" readwise; then
    echo "${YELLOW}→ Installing Readwise CLI (bun global)...${NC}"
    "$bun" install -g @readwise/cli@latest
    echo "${GREEN}✓ readwise installed — update with: nix run ~/nix#update-ai-tools${NC}"
  fi
  # Idempotent login so semantic search works in headless/background shells.
  if [ -n "${READWISE_TOKEN:-}" ] && command -v readwise >/dev/null 2>&1; then
    if readwise login-with-token "$READWISE_TOKEN" >/dev/null 2>&1; then
      echo "${GREEN}✓ readwise authenticated from \$READWISE_TOKEN${NC}"
    else
      echo "${YELLOW}⚠ readwise login-with-token failed — check \$READWISE_TOKEN${NC}"
    fi
  fi

  # 2) Custom edwinhu/readwise-cli (bun --compile) -> `readwise-custom`.
  local repo="$HOME/projects/readwise-cli"
  if want "readwise-custom" readwise-custom; then
    if [ ! -d "$repo/.git" ]; then
      echo "${YELLOW}→ Cloning edwinhu/readwise-cli...${NC}"
      mkdir -p "$HOME/projects"
      git clone git@github.com:edwinhu/readwise-cli.git "$repo" \
        || { echo "${RED}clone failed (SSH auth to GitHub?).${NC}" >&2; return 1; }
    fi
    echo "${YELLOW}→ Building readwise-custom (bun --compile)...${NC}"
    ( cd "$repo" && "$bun" install && "$bun" run build ) \
      || { echo "${RED}readwise-custom build failed.${NC}" >&2; return 1; }
    mkdir -p "$HOME/.local/bin"
    ln -sf "$repo/readwise" "$HOME/.local/bin/readwise-custom"
    echo "${GREEN}✓ readwise-custom → $repo/readwise${NC}"
  elif [ "$FORCE" = "1" ] && [ -d "$repo/.git" ]; then
    echo "${YELLOW}→ Updating + rebuilding readwise-custom...${NC}"
    git -C "$repo" pull --ff-only 2>/dev/null || true
    ( cd "$repo" && "$bun" install && "$bun" run build ) \
      && ln -sf "$repo/readwise" "$HOME/.local/bin/readwise-custom" \
      || echo "${YELLOW}⚠ readwise-custom rebuild failed — keeping existing binary.${NC}"
  fi
}

# Gemini CLI was renamed to Antigravity CLI at I/O 2026; consumer access to the
# old `gemini` binary stops 2026-06-18. Binary is `agy`; config still lives
# under ~/.gemini/antigravity-cli/, and `agy plugin import gemini` migrates
# existing extensions on first launch.
install_agy() {
  purge_nix_wrapper agy
  purge_nix_wrapper gemini
  if ! want "agy" agy; then return 0; fi
  echo "${YELLOW}→ Installing Antigravity CLI (official installer)...${NC}"
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  echo "${GREEN}✓ Antigravity CLI installed — run \`agy\` to sign in (or authenticate via Antigravity IDE first).${NC}"
}

# `gemini` subcommand kept for muscle memory; installs Antigravity CLI now.
install_gemini() { install_agy; }

for t in "${TOOLS[@]}"; do
  case "$t" in
    claude)       install_claude ;;
    codex)        install_codex ;;
    opencode)     install_opencode ;;
    gemini)       install_gemini ;;
    agy)          install_agy ;;
    qmd)          install_qmd ;;
    readwise)     install_readwise ;;
  esac
done

echo ""
echo "${GREEN}Done.${NC} Each tool manages its own updates going forward."
