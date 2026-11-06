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

# ---- hc (Herdr app) path ------------------------------------------------------------------------
# Taken from the built script when it already carries the hc path, else from default.nix with the
# nix '' escapes undone. Stub hc/herdr-app record calls; nothing reaches the real window.
HC_SRC="$SPAWNER"
if ! grep -q 'hc run --bg' "$HC_SRC"; then
  HC_SRC="$WORK/default.nix.sh"
  sed "s/''\\\${/\${/g" "$(dirname "$0")/../default.nix" > "$HC_SRC"
fi
sed -n '/^    if command -v hc >\/dev\/null/,/^    command -v herdr >\/dev\/null/p' "$HC_SRC" | sed '$d' > "$WORK/hc-block.sh"
grep -q 'hc run --bg' "$WORK/hc-block.sh" || { echo "could not extract the hc path" >&2; exit 2; }

mkdir -p "$WORK/hcbin"
cat > "$WORK/hcbin/hc" <<STUB
#!/usr/bin/env bash
echo "hc \$*" >> "$WORK/hc.log"
case "\$1 \${2:-}" in
  "server status") exit 0 ;;
  "get vault-compile") [ -n "\${OLD_JSON:-}" ] && printf '%s' "\$OLD_JSON" || exit 1 ;;
  "get t9") printf '{"state":"live","turn":1,"status":{"state":"working"}}' ;;
  "run --bg") printf '{"address":"t9"}' ;;
  "kill vault-compile") : ;;
  *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "herdr-app $*" >> "%s/hc.log"\n[ "$1" = ls ] && printf %%s "{\\"spaces\\":[{\\"id\\":\\"spR\\",\\"name\\":\\"Routines\\",\\"machine\\":null,\\"tabs\\":[]}]}"\nexit 0\n' "$WORK" > "$WORK/hcbin/herdr-app"
chmod +x "$WORK/hcbin/hc" "$WORK/hcbin/herdr-app"

run_hc() {   # old-json prompt -> exit code; log in hc.log
  : > "$WORK/hc.log"
  OLD_JSON="$1" PATH="$WORK/hcbin:$PATH" DIR=/tmp LABEL=vault-compile AGENT_NAME=vault-compile \
    PROMPT="$2" CLAUDE_AGENT="" ARGS_CMD="" \
    bash -c "set -uo pipefail; $(cat "$WORK/hc-block.sh"); echo FELL_THROUGH" >/dev/null 2>&1
}
old() { printf '{"state":"live","address":"t3","status":{"state":"%s"}}' "$1"; }

echo "claude-herdr-spawn hc path"

run_hc "" "/vault-compile"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'hc run --bg --json --name vault-compile --cwd /tmp --outlive-parent' "$WORK/hc.log" \
  && grep -q -- '-- claude --remote-control vault-compile --effort medium -n vault-compile /vault-compile$' "$WORK/hc.log" \
  && pass "starts via hc run --bg --outlive-parent with --remote-control <name> and the prompt last" \
  || fail "starts via hc run --bg --outlive-parent" "rc=$rc log: $(cat "$WORK/hc.log")"

grep -q -- '--label herdr.space=spR' "$WORK/hc.log" && grep -q -- '--label herdr.tab=tb' "$WORK/hc.log" \
  && pass "lands in the existing Routines space with a fresh tab label" \
  || fail "lands in the existing Routines space" "$(cat "$WORK/hc.log")"

grep -q 'herdr-app do tab.rename --id tb.* --name vault-compile' "$WORK/hc.log" \
  && pass "tab is renamed to the routine label" || fail "tab rename" "$(cat "$WORK/hc.log")"

run_hc "$(old done)" ""; grep -q '^hc kill vault-compile' "$WORK/hc.log" \
  && pass "a finished live agent holding the name is killed" || fail "finished agent reclaimed" "$(cat "$WORK/hc.log")"

run_hc "$(old idle)" ""; grep -q '^hc kill vault-compile' "$WORK/hc.log" \
  && pass "an idle agent is killed too" || fail "idle agent reclaimed" "$(cat "$WORK/hc.log")"

run_hc "$(old working)" ""; grep -q '^hc kill' "$WORK/hc.log" \
  && fail "a WORKING agent is never killed" "$(cat "$WORK/hc.log")" || pass "a WORKING agent is never killed"

run_hc "$(old blocked)" ""; grep -q '^hc kill' "$WORK/hc.log" \
  && fail "a blocked agent is left alone" "$(cat "$WORK/hc.log")" || pass "a blocked agent is left alone"

if [ "$FAILED" -eq 0 ]; then
  echo "claude-herdr-spawn: all reclaim assertions pass"
  exit 0
fi
echo "claude-herdr-spawn: reclaim assertions FAILED" >&2
exit 1
