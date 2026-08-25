# Resolve the bun the tests should run under. Sourced, not executed.
#
# The 1.4.0 pin lives in the working tree but has not been switched, so the
# profile `bun` is still 1.3.14. Prefer what will actually ship.
pinned_bun() {
  if [ -n "${BUN:-}" ] && [ -x "$BUN" ]; then echo "$BUN"; return 0; fi

  local built
  built=$(ls -d /nix/store/*-bun-[0-9]*/bin/bun 2>/dev/null | while read -r b; do
    case "$("$b" --revision 2>/dev/null)" in 1.4.*|1.[5-9].*|[2-9].*) echo "$b" ;; esac
  done | head -n1)
  if [ -n "$built" ]; then echo "$built"; return 0; fi

  local mise="$HOME/.local/share/mise/installs/bun/1.4.0/bin/bun"
  if [ -x "$mise" ]; then echo "$mise"; return 0; fi

  command -v bun
}
