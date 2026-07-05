#!/usr/bin/env bash
# check-my-tools.sh - Check my own edwinhu release-pinned nix packages for updates.
#
# Checks the version pinned in modules/shared/<pkg>.nix against the latest
# GitHub release for each of my own tools (superhuman-cli, morgen-cli).
#
# Usage:
#   scripts/check-my-tools.sh            Check mode. Prints one line per pkg;
#                                        exits non-zero if anything is BEHIND (CI-friendly).
#   scripts/check-my-tools.sh --update   For any BEHIND pkg, bump the version string in
#                                        its .nix and recompute the SRI hash(es) for each
#                                        platform asset, then rewrite the file.
#
# Requires: gh (authenticated), nix, sed, grep.

set -euo pipefail

# Resolve repo root (parent of this script's dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-pkg config: name | github repo | asset-URL template (v${version} placeholder as {V}).
# Add a new tool here and it is checked/updated automatically.
TOOLS=(
  "superhuman-cli|edwinhu/superhuman-cli|https://github.com/edwinhu/superhuman-cli/releases/download/v{V}/superhuman"
  "morgen-cli|edwinhu/morgen-cli|https://github.com/edwinhu/morgen-cli/releases/download/v{V}/morgen-darwin-arm64"
)

UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

behind_any=0

read_pinned() {
  # $1 = nix file path -> prints pinned version string
  grep -oE 'version = "[^"]+"' "$1" | head -1 | sed -E 's/version = "([^"]+)"/\1/'
}

latest_release() {
  # $1 = repo -> prints latest tag with leading v stripped
  gh release view --repo "$1" --json tagName -q .tagName | sed -E 's/^v//'
}

for entry in "${TOOLS[@]}"; do
  IFS='|' read -r pkg repo url_tmpl <<< "$entry"
  nix_file="$REPO_ROOT/modules/shared/$pkg.nix"

  if [[ ! -f "$nix_file" ]]; then
    echo "$pkg: MISSING $nix_file"
    behind_any=1
    continue
  fi

  pinned="$(read_pinned "$nix_file")"
  latest="$(latest_release "$repo")"

  if [[ "$pinned" == "$latest" ]]; then
    status="UP-TO-DATE"
  else
    status="BEHIND"
    behind_any=1
  fi

  echo "$pkg: pinned $pinned | latest $latest | $status"

  if [[ "$UPDATE" -eq 1 && "$status" == "BEHIND" ]]; then
    echo "  -> updating $pkg $pinned -> $latest"

    # Bump version string.
    sed -i '' -E "s/version = \"$pinned\"/version = \"$latest\"/" "$nix_file"

    # Recompute SRI hash for each platform asset. The URL template's {V} is the
    # version; we fetch the concrete asset and grab its store SRI hash.
    asset_url="${url_tmpl//\{V\}/$latest}"
    new_hash="$(nix store prefetch-file --json "$asset_url" | grep -oE '"hash":"[^"]+"' | sed -E 's/"hash":"([^"]+)"/\1/')"

    if [[ -z "$new_hash" ]]; then
      echo "  !! failed to prefetch hash for $asset_url" >&2
      exit 1
    fi

    # Replace any existing sha256- SRI hash line(s) in the file.
    sed -i '' -E "s#hash = \"sha256-[^\"]+\"#hash = \"$new_hash\"#g" "$nix_file"

    echo "  -> version=$latest hash=$new_hash"
  fi
done

if [[ "$UPDATE" -eq 0 && "$behind_any" -ne 0 ]]; then
  exit 1
fi
exit 0
