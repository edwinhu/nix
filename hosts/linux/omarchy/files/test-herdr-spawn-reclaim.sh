#!/usr/bin/env bash
# Contract for claudeHerdrSpawn's name-reclaim block (hosts/linux/omarchy/default.nix).
#
# herdr scopes live agent names uniquely and a finished agent keeps its name, so a nightly routine
# is blocked forever by its OWN previous run (agent_name_taken ate the 2026-09-20 and -21
# vault-compile runs). The retry loop around `agent start` cannot clear that -- it exists for
# transient "pane is not an available shell" errors -- so the spawner closes the stale tab first.
#
# The block is extracted from the BUILT script and run against a stub `herdr` on PATH: it must
# close a tab whose agent is finished, and must NEVER close one that is still working, because a
# nightly overrunning into the next night's slot must not be killed to start a duplicate.
#
# Run: bash hosts/linux/omarchy/files/test-herdr-spawn-reclaim.sh
# Exit 0 pass, 1 a contract assertion failed, 2 could not run (no built spawner -- build first).
set -uo pipefail

SPAWNER="${1:-}"
if [ -z "$SPAWNER" ]; then
  unit=$(systemctl --user cat claude-vault-compile.service 2>/dev/null | grep -m1 '^ExecStart=' | cut -d= -f2-)
  [ -n "$unit" ] && SPAWNER=$(grep -oE '/nix/store/[a-z0-9]+-claude-herdr-spawn' "$unit" 2>/dev/null | head -1)
fi
if [ -z "${SPAWNER:-}" ] || [ ! -r "$SPAWNER" ]; then
  echo "no built claude-herdr-spawn found (pass one as \$1, or nix run .#build-switch first)" >&2
  exit 2
fi
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAILED=1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# The reclaim block, verbatim from the built script: from its banner comment to the line that
# begins the start loop. Extracting rather than reimplementing is the point -- a copy would drift.
sed -n '/# RECLAIM OUR OWN NAME FIRST/,/^    STARTED=""/p' "$SPAWNER" | sed '$d' > "$WORK/block.sh"
if ! grep -q "reclaiming the name" "$WORK/block.sh"; then
  echo "could not extract the reclaim block from $SPAWNER" >&2
  exit 2
fi

# stub herdr: `agent list` prints $AGENTS_JSON, `tab close <id>` records the id.
cat > "$WORK/bin/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "agent list") printf '%s' "\$AGENTS_JSON" ;;
  "tab close")  echo "\$3" >> "$WORK/closed.txt" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/herdr"

run_case() {   # name, agents-json  -> prints what was closed
  : > "$WORK/closed.txt"
  AGENTS_JSON="$2" AGENT_NAME="$1" PATH="$WORK/bin:$PATH" \
    bash -c "set -uo pipefail; AGENT_NAME=\"\$AGENT_NAME\"; $(cat "$WORK/block.sh")" 2>/dev/null
  cat "$WORK/closed.txt" 2>/dev/null | tr -d '\n'
}

agents() {     # status -> one agent named vault-compile in tab wEM:t1
  printf '{"result":{"agents":[{"name":"vault-compile","agent_status":"%s","tab_id":"wEM:t1","pane_id":"wEM:p1"}]}}' "$1"
}

echo "claude-herdr-spawn name-reclaim contract"

closed=$(run_case vault-compile "$(agents done)")
[ "$closed" = "wEM:t1" ] \
  && pass "a finished agent's tab is closed so the name can be taken" \
  || fail "a finished agent's tab is closed so the name can be taken" "closed='$closed', wanted wEM:t1"

closed=$(run_case vault-compile "$(agents idle)")
[ "$closed" = "wEM:t1" ] \
  && pass "an idle agent's tab is closed too" \
  || fail "an idle agent's tab is closed too" "closed='$closed', wanted wEM:t1"

closed=$(run_case vault-compile "$(agents working)")
[ -z "$closed" ] \
  && pass "a WORKING agent is never killed to start a duplicate" \
  || fail "a WORKING agent is never killed to start a duplicate" "closed='$closed', wanted nothing"

closed=$(run_case vault-compile "$(agents blocked)")
[ -z "$closed" ] \
  && pass "a blocked agent is left alone (it is waiting on a human, not finished)" \
  || fail "a blocked agent is left alone (it is waiting on a human, not finished)" "closed='$closed'"

closed=$(run_case morning-briefing "$(agents done)")
[ -z "$closed" ] \
  && pass "another routine's finished agent is not ours to close" \
  || fail "another routine's finished agent is not ours to close" "closed='$closed', wanted nothing"

closed=$(run_case vault-compile '{"result":{"agents":[]}}')
[ -z "$closed" ] \
  && pass "no agents at all is a no-op" \
  || fail "no agents at all is a no-op" "closed='$closed'"

closed=$(run_case vault-compile 'mise ~/.config/mise/config.toml tools: herdr@0.9.1')
[ -z "$closed" ] \
  && pass "unparseable output closes nothing (the mise banner must not become a close)" \
  || fail "unparseable output closes nothing" "closed='$closed'"

if [ "$FAILED" -eq 0 ]; then
  echo "claude-herdr-spawn: all reclaim assertions pass"
  exit 0
fi
echo "claude-herdr-spawn: reclaim assertions FAILED" >&2
exit 1
