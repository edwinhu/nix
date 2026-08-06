#!/usr/bin/env bash
# Add or rotate ONE secret in ~/nix-secrets, then print how to wire it up.
#
#   ./add-api-keys.sh permacc-api-key           # prompt for the value
#   ./add-api-keys.sh permacc-api-key --stdin   # read it from a pipe
#   ./add-api-keys.sh --list                    # what is already encrypted
#
# WHAT THIS REPLACES, AND WHY IT WAS BROKEN
#
#   The previous version encrypted four hardcoded keys with `sops` into
#   ~/nix-secrets/secrets.yaml. That file does not exist and never did: this
#   repo is agenix -- one age-encrypted file per secret, with recipients
#   declared in secrets.nix. Running it would have written a secrets.yaml
#   nothing reads, committed it, and pushed. The keys would have looked saved.
#
#   It was also all-or-nothing by construction: it prompted for all four and
#   rewrote the file from those four answers, so leaving one blank to add
#   another erased it. Per-secret is not a refinement here, it is the fix.
#
# WHY IT CALLS `age` DIRECTLY RATHER THAN `agenix`
#
#   agenix is a flake input, not an installed binary -- `agenix` is not on
#   PATH, which is where this script previously dead-ended. An agenix file is
#   an ordinary age file encrypted to the recipients secrets.nix lists, so
#   `age -r ... -o name.age` produces a byte-identical result with a binary
#   that IS installed. Verified against readwise-token.age: same header, same
#   three recipient stanzas.
set -euo pipefail

SECRETS="${NIX_SECRETS_DIR:-$HOME/nix-secrets}"
NIXCFG="${NIX_CONFIG_DIR:-$HOME/nix}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[1;33m%s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m%s\033[0m\n' "$*"; }

command -v age >/dev/null || die "age not found on PATH"
[ -d "$SECRETS" ] || die "no such directory: $SECRETS"
[ -f "$SECRETS/secrets.nix" ] || die "no secrets.nix in $SECRETS"

if [ "${1:-}" = "--list" ]; then
    ls -1 "$SECRETS"/*.age 2>/dev/null | xargs -n1 basename | sed 's/\.age$//'
    exit 0
fi

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: $0 <secret-name> [--stdin] | --list"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase-with-dashes: $NAME"
NAME="${NAME%.age}"
FILE="$SECRETS/$NAME.age"

# --- recipients -----------------------------------------------------------
# Every age/ssh public key spelled in secrets.nix. Preferred path is asking
# nix, which resolves `users ++ systems` exactly as agenix would; the regex
# fallback exists because this script is most useful on a machine where the
# nix CLI is not on PATH -- which is the situation that sent someone here.
recipients() {
    if command -v nix >/dev/null 2>&1 &&
       out=$(cd "$SECRETS" && nix eval --file secrets.nix --json \
             --apply "x: x.\"$NAME.age\".publicKeys or []" 2>/dev/null) &&
       [ "$out" != "[]" ]; then
        printf '%s' "$out" | tr -d '[]"' | tr ',' '\n' | sed '/^$/d'
        return
    fi
    grep -oE '"(ssh-(ed25519|rsa) [^"]+|age1[^"]+)"' "$SECRETS/secrets.nix" | tr -d '"' | sort -u
}

mapfile -t RECIPIENTS < <(recipients)
[ "${#RECIPIENTS[@]}" -gt 0 ] || die "no recipients found in $SECRETS/secrets.nix"

# --- declare it before encrypting -----------------------------------------
# An .age file whose name is absent from secrets.nix is invisible to agenix
# and to `agenix --rekey`: it decrypts today and is silently left behind at
# the next key rotation. Declaring first makes that impossible to forget.
if ! grep -q "\"$NAME.age\"" "$SECRETS/secrets.nix"; then
    note "declaring $NAME.age in secrets.nix"
    tmp=$(mktemp)
    awk -v entry="  \"$NAME.age\".publicKeys = users ++ systems;" '
        /^\}/ && !done { print entry; done = 1 }
        { print }
    ' "$SECRETS/secrets.nix" > "$tmp"
    grep -q "\"$NAME.age\"" "$tmp" || { rm -f "$tmp"; die "could not place the entry; add it by hand"; }
    mv "$tmp" "$SECRETS/secrets.nix"
fi

# --- the value ------------------------------------------------------------
if [ "${2:-}" = "--stdin" ] || [ ! -t 0 ]; then
    VALUE=$(cat)
else
    [ -e "$FILE" ] && note "$NAME.age exists; this will REPLACE it"
    printf 'Enter value for %s (input hidden): ' "$NAME"
    read -rs VALUE
    echo
fi
VALUE="${VALUE%$'\n'}"
[ -n "$VALUE" ] || die "empty value; nothing written"

# --- encrypt --------------------------------------------------------------
# Written to a temp file first: `age -o` on the real path would truncate the
# existing secret before it knows whether encryption succeeds, and a failed
# rotation that destroys the working key is the worst outcome here.
args=(); for r in "${RECIPIENTS[@]}"; do args+=(-r "$r"); done
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf '%s' "$VALUE" | age -e "${args[@]}" -o "$tmp"
[ -s "$tmp" ] || die "age produced nothing"
mv "$tmp" "$FILE"; trap - EXIT
ok "wrote $FILE (${#RECIPIENTS[@]} recipients)"

# --- commit ---------------------------------------------------------------
if git -C "$SECRETS" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$SECRETS" add "$NAME.age" secrets.nix
    git -C "$SECRETS" commit -qm "Add $NAME" && ok "committed"
    if git -C "$SECRETS" push -q 2>/dev/null; then
        ok "pushed"
    else
        note "push failed -- do it by hand; an unpushed secret is invisible to the flake"
    fi
fi

# --- wiring ---------------------------------------------------------------
VAR=$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')
cat <<EOF

$(note "Add to $NIXCFG/modules/shared/home-secrets.nix:")

  age.secrets:          $NAME = { file = "\${nix-secrets}/$NAME.age"; mode = "400"; };
  sessionVariables:     ${VAR}_FILE = "\${tempDir}/$NAME";
  shellAliases:         get-$NAME = "cat \$${VAR}_FILE";

$(note "Then, in $NIXCFG:")

  nix flake update nix-secrets && nix run .#build-switch

nix-secrets is a flake input pinned by revision, so pushing is NOT enough --
without the lock bump the build still sees the old commit and the new secret
does not exist as far as the system is concerned.

Reading it afterwards: the convention here exports a PATH, not a value.

  cat \$${VAR}_FILE          # or: get-$NAME
EOF
