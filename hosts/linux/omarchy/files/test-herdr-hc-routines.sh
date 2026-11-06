#!/usr/bin/env bash
# Contract for the hc (Herdr app) path of claudeHerdrDeliver, the assistant keepalive and the
# assistant shutdown routine (hosts/linux/omarchy/default.nix). The scripts are extracted from
# default.nix and run against a stub `hc` on PATH; nothing reaches a real terminal.
#
# Invariants: a live idle assistant is never respawned or killed; a working one is never
# interrupted; the assistant is recognised by hc name OR by Claude session name.
#
# Run: bash hosts/linux/omarchy/files/test-herdr-hc-routines.sh   (exit 0 pass, 1 fail, 2 cannot run)
set -uo pipefail
SRC="$(dirname "$0")/../default.nix"
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAILED=1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/terms" "$WORK/claude/sessions" "$WORK/home/areas/assistant"
AD="$WORK/home/areas/assistant"

extract() {   # nix writeShellScript NAME body, nix '' escapes undone, helper refs -> stubs
  awk -v n="writeShellScript \"$1\" ''" 'index($0,n){f=1;next} f&&/^ *'"''"';$/{exit} f' "$SRC" \
    | sed "s/''\\\${/\${/g; s/'''/''/g" \
    | sed "s#\\\${claudeHerdrDeliver}#$WORK/deliver.sh#g; s#\\\${claudeHerdrSpawn}#$WORK/spawn.sh#g"
}
extract claude-herdr-deliver > "$WORK/deliver.sh"
extract claude-assistant-keepalive > "$WORK/keepalive.sh"
extract claude-assistant-shutdown > "$WORK/shutdown.sh"
for f in deliver keepalive shutdown; do
  [ -s "$WORK/$f.sh" ] || { echo "could not extract $f" >&2; exit 2; }
  bash -n "$WORK/$f.sh" || { echo "$f does not parse" >&2; exit 2; }
done
grep -q 'hc send --if idle' "$WORK/deliver.sh" || { echo "deliver has no hc path" >&2; exit 2; }
printf '#!/usr/bin/env bash\necho "SPAWN $*" >> "%s/log"\n' "$WORK" > "$WORK/spawn.sh"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "agents --json" ] && echo "[]"\nexit 0\n' > "$WORK/bin/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/herdr"

# stub hc: terminals are $WORK/terms/*.json; /clear rotates the session id; send bumps turn.
cat > "$WORK/bin/hc" <<STUB
#!/usr/bin/env bash
echo "hc \$*" >> "$WORK/log"
T="$WORK/terms"
find_t() { for f in "\$T"/*.json; do [ -e "\$f" ] || continue
  jq -e --arg k "\$1" '.address==\$k or .name==\$k' "\$f" >/dev/null 2>&1 && { echo "\$f"; return 0; }; done; return 1; }
case "\$1" in
  server) exit 0 ;;
  ls) jq -s '{terminals: .}' "\$T"/*.json 2>/dev/null ;;
  get) f=\$(find_t "\$2") && cat "\$f" || { echo '{"error":{"kind":"not_found"}}'; exit 1; } ;;
  send) shift; ifidle=0; [ "\$1" = --if ] && { ifidle=1; shift 2; }
    f=\$(find_t "\$1") || exit 1
    [ "\$ifidle" = 0 ] || [ "\$(jq -r .status.state "\$f")" = idle ] || exit 1
    pid=\$(jq -r .foreground.pid "\$f")
    if [ "\$2" = /clear ]; then jq '.sessionId="new-session"' "$WORK/claude/sessions/\$pid.json" > "$WORK/s.tmp" && mv "$WORK/s.tmp" "$WORK/claude/sessions/\$pid.json"
    else jq '.turn+=1' "\$f" > "$WORK/s.tmp" && mv "$WORK/s.tmp" "\$f"; fi ;;
  keys|kill|rm) : ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/"* "$WORK"/*.sh

# term <file> <address> <name|""> <state> <session-name>   (foreground pid 4242 + its session file)
term() {
  jq -n --arg a "$2" --arg n "$3" --arg s "$4" --arg d "$AD" \
    '{address:$a,state:"live",status:{app:"claude-code",state:$s},turn:0,cwd:$d,foreground:{pid:4242}} + (if $n=="" then {} else {name:$n} end)' > "$WORK/terms/$1.json"
  jq -n --arg n "$5" '{pid:4242,sessionId:"old-session",name:$n}' > "$WORK/claude/sessions/4242.json"
}
reset() { rm -f "$WORK/terms"/*.json "$WORK/log"; : > "$WORK/log"; }
run() {  # script args... -> rc
  ( cd "$AD" && HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/claude" PATH="$WORK/bin:$PATH" bash "$@" ) >"$WORK/out" 2>&1
}
logged() { grep -q -- "$1" "$WORK/log"; }
check() { # desc rc
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1" "log: $(tr '\n' '|' < "$WORK/log") out: $(tr '\n' '|' < "$WORK/out")"; fi
}

echo "claudeHerdrDeliver hc path"
reset; term a t1f assistant idle Assistant
run "$WORK/deliver.sh" assistant "" Assistant; rc=$?
[ $rc -eq 0 ] && ! logged '^hc send'; check "idle assistant, empty text: alive (0), nothing typed" $?

reset
run "$WORK/deliver.sh" assistant "" Assistant; rc=$?
[ $rc -eq 3 ]; check "no terminal at all: 3" $?

reset; term a t1f handmade idle Assistant
run "$WORK/deliver.sh" assistant "" Assistant; rc=$?
[ $rc -eq 0 ]; check "found by Claude session name when the hc name differs" $?

reset; term a t1f handmade idle Other
run "$WORK/deliver.sh" assistant "" Assistant; rc=$?
[ $rc -eq 3 ]; check "a different session name is not the assistant: 3" $?

reset; term a t1f assistant working Assistant
run "$WORK/deliver.sh" assistant "hello" Assistant; rc=$?
[ $rc -eq 1 ] && ! logged '^hc send'; check "WORKING assistant is never typed into" $?

reset; term a t1f assistant blocked Assistant
run "$WORK/deliver.sh" assistant /clear Assistant; rc=$?
[ $rc -eq 1 ] && ! logged '^hc send' && ! logged '^hc keys'; check "blocked assistant gets nothing, not even Enter" $?

reset; term a t1f assistant idle Assistant
run "$WORK/deliver.sh" assistant /clear Assistant; rc=$?
[ $rc -eq 0 ] && logged '^hc send --if idle t1f /clear' && ! logged '^hc kill'; check "idle /clear: sent with --if idle, session id changed, not killed" $?

reset; term a t1f assistant idle Assistant
run "$WORK/deliver.sh" assistant "do the thing" Assistant; rc=$?
[ $rc -eq 0 ] && logged '^hc send --if idle t1f do the thing'; check "idle text delivered, confirmed by turn advance" $?

echo "claude-assistant-keepalive"
reset; term a t1f assistant idle Assistant
run "$WORK/keepalive.sh"; rc=$?
[ $rc -eq 0 ] && ! logged SPAWN && ! logged '^hc kill' && ! logged '^hc rm'; check "live IDLE assistant: no respawn, no kill" $?

reset; term a t1f assistant working Assistant
run "$WORK/keepalive.sh"; rc=$?
[ $rc -eq 0 ] && ! logged SPAWN && ! logged '^hc kill' && ! logged '^hc send'; check "WORKING assistant: untouched" $?

reset; term a t1f handmade idle Assistant
run "$WORK/keepalive.sh"; rc=$?
[ $rc -eq 0 ] && ! logged SPAWN && ! logged '^hc kill'; check "assistant under another hc name (session name Assistant): no duplicate" $?

reset
run "$WORK/keepalive.sh"; rc=$?
[ $rc -eq 0 ] && logged "SPAWN $AD Assistant assistant"; check "no assistant anywhere: spawns one named assistant" $?

echo "claude-assistant-shutdown"
reset; term a t1f assistant idle Assistant
run "$WORK/shutdown.sh"; rc=$?
[ $rc -eq 0 ] && logged '^hc send --if idle t1f /clear' && ! logged '^hc kill'; check "idle assistant is /cleared, never killed" $?

reset; term a t1f assistant working Assistant
run "$WORK/shutdown.sh"; rc=$?
[ $rc -ne 0 ] && ! logged '^hc send' && ! logged '^hc kill'; check "WORKING assistant is not interrupted (reported as failed, not forced)" $?

reset; term a t1f assistant idle Assistant
jq -n '{address:"t2",name:"nightly-wrapup",state:"live",status:{state:"done"},cwd:"/tmp",foreground:{pid:1}}' > "$WORK/terms/b.json"
run "$WORK/shutdown.sh"; rc=$?
[ $rc -eq 0 ] && logged '^hc kill nightly-wrapup' && logged '^hc rm nightly-wrapup' && ! logged '^hc kill assistant' && ! logged '^hc kill t1f'; check "nightly-wrapup closed via hc; assistant spared" $?

if [ "$FAILED" -eq 0 ]; then echo "hc routines: all assertions pass"; exit 0; fi
echo "hc routines: assertions FAILED" >&2; exit 1
