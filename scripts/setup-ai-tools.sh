#!/usr/bin/env bash
# Bootstrap installer for AI CLI tools.
#
# Tools that ship prebuilt binaries (claude, codex, opencode, agy, atuin)
# install through mise: this writes a small stub into ~/.local/bin that resolves and
# updates the tool on every run, so nothing here pins a version and nothing
# fights the tools' own release cadence. Same mechanism Omarchy 4 uses
# (omarchy-mise-install), reimplemented so it also works on macOS and
# non-Omarchy Linux, where that binary doesn't exist.
#
# qmd and readwise stay on `bun install -g`: mise's npm backend installs via
# aube, which skips native postinstall — qmd's better-sqlite3 binding then
# never builds, and @readwise/cli's install aborts. Don't "unify" them onto
# mise without re-testing `qmd collection list` and `readwise --help`.
#
# Install all:   bash ~/nix/scripts/setup-ai-tools.sh
# Install one:   bash ~/nix/scripts/setup-ai-tools.sh claude
# Update all:    bash ~/nix/scripts/setup-ai-tools.sh --force
# Skip some:     AI_TOOLS_SKIP="readwise" bash ~/nix/scripts/setup-ai-tools.sh
#                (per-host default, set via userInfo.aiToolsSkip in flake.nix;
#                 ignored for tools named explicitly on the command line)
#
# Or via nix:    nix run ~/nix#setup-ai-tools
#                nix run ~/nix#update-ai-tools

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
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    claude|codex|opencode|gemini|agy|qmd|readwise|atuin) TOOLS+=("$arg") ;;
    *)
      echo "${RED}Unknown argument: $arg${NC}" >&2
      exit 1
      ;;
  esac
done
if [ ${#TOOLS[@]} -eq 0 ]; then
  TOOLS=(claude codex opencode agy qmd readwise atuin)
  # Per-host opt-out. AI_TOOLS_SKIP is a space-separated tool list, set from
  # `userInfo.aiToolsSkip` in flake.nix, for hosts that don't want part of the
  # default set (e.g. rjds has no use for readwise, and installing it there
  # means a git clone + bun compile on every switch, plus a login warning for
  # a token that host never needs).
  #
  # Only filters the DEFAULT set: naming a tool on the command line always
  # installs it, so `setup-ai-tools.sh readwise` still works on a skip host.
  if [ -n "${AI_TOOLS_SKIP:-}" ]; then
    keep=()
    for t in "${TOOLS[@]}"; do
      skip=0
      for s in $AI_TOOLS_SKIP; do
        [ "$t" = "$s" ] && skip=1
      done
      [ "$skip" = "1" ] || keep+=("$t")
    done
    TOOLS=(${keep[@]+"${keep[@]}"})
    echo "${YELLOW}→ Skipping per AI_TOOLS_SKIP: ${AI_TOOLS_SKIP}${NC}"
  fi
fi

MISE=$(command -v mise 2>/dev/null || true)
if [ -z "$MISE" ]; then
  # mise comes from modules/shared/packages.nix (and from the Arch package on
  # Omarchy). A switch that hasn't been applied yet is the usual reason it's
  # missing, so say that rather than failing bare.
  echo "${RED}mise not found — run build-switch first.${NC}" >&2
  exit 1
fi

# Remove stale nix-era wrappers at ~/.local/bin/<tool> that exec into /nix/store.
# Before nix stopped managing these, build-switch wrote bash wrappers like
#   #!/bin/bash
#   exec "/nix/store/.../opencode" "$@"
# These break once nix GC reaps the store path.
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

# Write ~/.local/bin/<command> as a mise stub. Rewritten unconditionally: it is
# four lines, and that is what makes an install idempotent and a migration from
# a curl-installer binary automatic.
#
# MISE_MINIMUM_RELEASE_AGE=0 defeats mise's release cooldown, which otherwise
# withholds a new version for days after it ships — wrong for tools that
# release daily. Exported, not set on the `use` line alone, so the version
# resolved to execute agrees with the one just installed.
mise_stub() {
  local package=$1 command=${2:-$1} bin=${3:-${2:-$1}}
  local stub="$HOME/.local/bin/$command"
  mkdir -p "$HOME/.local/bin"
  rm -f "$stub"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
export MISE_MINIMUM_RELEASE_AGE=0
mise use -g "$package" || exit 1
exec mise x "$package" -- "$bin" "\$@"
EOF
  chmod +x "$stub"
  # Resolve now rather than on first launch, so a fresh machine finishes the
  # switch with working tools instead of a stub that downloads mid-session.
  if MISE_MINIMUM_RELEASE_AGE=0 "$MISE" use -g "$package" >/dev/null 2>&1; then
    echo "${GREEN}✓${NC} $command → mise $package"
  else
    echo "${YELLOW}⚠ $command stub written, but 'mise use -g $package' failed (offline?) — it will retry on first run.${NC}"
  fi
}

install_claude()   { purge_nix_wrapper claude;   mise_stub claude; }
install_codex()    { purge_nix_wrapper codex;    mise_stub codex; }
install_opencode() { purge_nix_wrapper opencode; mise_stub opencode; }

# Gemini CLI was renamed to Antigravity CLI at I/O 2026; consumer access to the
# old `gemini` binary stops 2026-06-18. Binary is `agy`; config still lives
# under ~/.gemini/antigravity-cli/, and `agy plugin import gemini` migrates
# existing extensions on first launch.
install_agy() {
  purge_nix_wrapper agy
  purge_nix_wrapper gemini
  mise_stub agy
}
# `gemini` subcommand kept for muscle memory; installs Antigravity CLI now.
install_gemini() { install_agy; }

# atuin — here rather than in nix's packages.nix because self-hosted Atuin AI
# (the local atuin-ai-server fronting cli-proxy-api; see
# ~/.config/atuin-ai/config.toml) landed in 18.19.0, and nixpkgs-unstable is
# still on 18.18.1. Upstream ships prebuilt binaries for every platform here,
# so mise's aqua:atuinsh/atuin resolves it directly.
#
# The nix profile precedes ~/.local/bin on PATH, so this only wins once atuin
# is gone from packages.nix — which it is. bash-preexec stays in nix.
install_atuin() {
  purge_nix_wrapper atuin
  mise_stub atuin
}

find_bun() {
  for p in "$HOME/.bun/bin/bun" "$HOME/.nix-profile/bin/bun"; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  "$MISE" which bun 2>/dev/null && return 0
  return 1
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

# qmd (tobi/qmd) — "Quick Markdown Search", a local BM25+vector search engine
# over the Obsidian vault. Secondary retrieval + compile-time discovery aid for
# the knowledge base (see ~/notes/.claude/CLAUDE.md; wired in ~/notes/scripts/
# qmd.py). Embeddings are NOT built here (slow, downloads a local GGUF model) —
# the nightly vault-compile's reindex step handles that; until then hybrid
# queries fall back to BM25.
install_qmd() {
  purge_nix_wrapper qmd
  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }
  if want "qmd" qmd; then
    echo "${YELLOW}→ Installing qmd (bun global)...${NC}"
    "$bun" install -g @tobilu/qmd@latest
  fi
  # Bootstrap the vault collection if the vault exists and isn't indexed yet.
  local qmd_bin
  qmd_bin=$(command -v qmd 2>/dev/null || echo "$HOME/.bun/bin/qmd")
  if [ -x "$qmd_bin" ] && [ -d "$HOME/notes" ]; then
    if ! "$qmd_bin" collection list 2>/dev/null | grep -q "^ *notes\b"; then
      echo "${YELLOW}→ Bootstrapping qmd 'notes' collection over ~/notes${NC}"
      "$qmd_bin" collection add "$HOME/notes" --name notes || true
    fi
  fi
}

# Readwise — TWO separate CLIs the `readwise`/librarian skill depends on:
#   readwise         official @readwise/cli. Provides semantic / vector
#                    highlight search:
#                      readwise readwise-search-highlights --vector-search-term …
#                    Its absence is what silently degrades the librarian to
#                    keyword-only raw-API calls (no semantic ranking).
#   readwise-custom  our own edwinhu/readwise-cli — a bun `--compile` single-file
#                    binary (RAG chat, keyword search, upload, prune,
#                    ghostreader). Downloaded from that repo's GitHub release
#                    rather than built here: the repo is private, so `gh` does
#                    the auth. Publish a new one by tagging v* (see its
#                    .github/workflows/release.yml).
# Auth needs no new secret: both resolve the token from the agenix-provided
# $READWISE_TOKEN env var. The official CLI also caches a login, which we set
# idempotently whenever a token is present.
install_readwise() {
  purge_nix_wrapper readwise
  purge_nix_wrapper readwise-custom

  local bun
  bun=$(find_bun) || { echo "${RED}bun not found — run build-switch first.${NC}" >&2; return 1; }
  if want "readwise (@readwise/cli)" readwise; then
    echo "${YELLOW}→ Installing Readwise CLI (bun global)...${NC}"
    "$bun" install -g @readwise/cli@latest
  fi
  # Idempotent login so semantic search works in headless/background shells.
  if [ -n "${READWISE_TOKEN:-}" ] && command -v readwise >/dev/null 2>&1; then
    if readwise login-with-token "$READWISE_TOKEN" >/dev/null 2>&1; then
      echo "${GREEN}✓ readwise authenticated from \$READWISE_TOKEN${NC}"
    else
      echo "${YELLOW}⚠ readwise login-with-token failed — check \$READWISE_TOKEN${NC}"
    fi
  fi

  local dest="$HOME/.local/bin/readwise-custom"
  # A symlink into ~/projects is a local dev build. Leave it alone — otherwise
  # --force would silently swap the working copy for the last release.
  if [ -L "$dest" ] && [[ "$(readlink "$dest")" == "$HOME/projects/"* ]]; then
    echo "${GREEN}✓${NC} readwise-custom is a dev build ($(readlink "$dest")) — not replacing"
    return 0
  fi
  if [ "$FORCE" != "1" ] && [ -x "$dest" ]; then
    echo "${GREEN}✓${NC} readwise-custom already installed"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "${YELLOW}⚠ gh not found — skipping readwise-custom (private repo needs it to download).${NC}"
    return 0
  fi
  local asset
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)          asset=readwise-custom-darwin-arm64 ;;
    Linux-x86_64)          asset=readwise-custom-linux-x64 ;;
    Linux-aarch64|Linux-arm64) asset=readwise-custom-linux-arm64 ;;
    *)
      echo "${YELLOW}⚠ no readwise-custom release asset for $(uname -s)-$(uname -m) — skipping.${NC}"
      return 0
      ;;
  esac
  echo "${YELLOW}→ Downloading readwise-custom ($asset)...${NC}"
  # Staged through a temp file so a failed download can't leave a truncated
  # binary at $dest, and so replacing a running one doesn't ETXTBSY.
  local tmp="$dest.new"
  if gh release download --repo edwinhu/readwise-cli \
       --pattern "$asset" --output "$tmp" --clobber 2>/dev/null; then
    chmod +x "$tmp"
    mkdir -p "$HOME/.local/bin"
    mv -f "$tmp" "$dest"
    echo "${GREEN}✓ readwise-custom → $dest${NC}"
  else
    rm -f "$tmp"
    echo "${YELLOW}⚠ readwise-custom download failed (gh auth? no release asset named $asset?) — keeping existing binary.${NC}"
  fi
}

for t in "${TOOLS[@]}"; do
  case "$t" in
    claude)       install_claude ;;
    codex)        install_codex ;;
    opencode)     install_opencode ;;
    gemini)       install_gemini ;;
    agy)          install_agy ;;
    qmd)          install_qmd ;;
    readwise)     install_readwise ;;
    atuin)        install_atuin ;;
  esac
done

# --force is the update path: bump every mise-managed tool past the cooldown.
# Cheap and global, so it runs once at the end rather than per tool.
if [ "$FORCE" = "1" ]; then
  echo "${YELLOW}→ Updating mise-managed tools...${NC}"
  MISE_MINIMUM_RELEASE_AGE=0 "$MISE" up || true
fi

echo ""
echo "${GREEN}Done.${NC} Tools self-update on each run; force a bump with: nix run ~/nix#update-ai-tools"
