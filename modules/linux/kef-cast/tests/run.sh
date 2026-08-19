#!/usr/bin/env bash
# Red suite for kef-cast.
#
# Drives the REAL wrapper script out of the nix build, with catt/pactl/kefctl/ip
# stubbed, so no test touches the speaker or this machine's audio. The stubs
# record every call with a timestamp; the assertions read that record.
#
# The wrapper is copied and its `export PATH=` line rewritten, because
# writeShellApplication PREPENDS its runtimeInputs to PATH — a stub directory
# added from outside would be shadowed by the real catt every time.
#
# Whether the stub `catt cast` succeeds is controlled by the presence of a
# `cast_fails` file in the sandbox, so a test can flip it mid-run.
#
# Sub-commands: reconnect | no-spurious | backoff | reset | logging | give-up |
#               retry-forever | impostor | cast-hang | cleanup | exit-status |
#               stranger | timeout-failed | teardown
# Groups (each stays under the gate's 2-minute per-check cap): core | watchdog | recovery | all

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"

STORE=""
SANDBOXES=()

cleanup_all() {
  for d in ${SANDBOXES+"${SANDBOXES[@]}"}; do
    [ -f "$d/wrapper.pid" ] && kill "$(cat "$d/wrapper.pid")" 2>/dev/null
  done
  sleep 0.3
  for d in ${SANDBOXES+"${SANDBOXES[@]}"}; do rm -rf "$d"; done
}
trap cleanup_all EXIT

build_wrapper() {
  nix build --no-link --print-out-paths --impure --expr \
    "let f = builtins.getFlake \"$ROOT\"; pkgs = f.homeConfigurations.eh.pkgs; in import $ROOT/modules/linux/kef-cast { inherit pkgs; }" \
    2>/dev/null | tail -1
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

make_sandbox() {  # $1 dir, $2 speaker ip the stub kefctl reports
  local dir=$1 speaker=$2
  mkdir -p "$dir/bin"
  : > "$dir/calls.log"

  # Defaults to 127.0.0.1 so the loopback fake client IS the speaker. A test
  # that wants an IMPOSTOR passes a different address: the client then connects
  # from 127.0.0.1 while the wrapper believes the speaker lives elsewhere.
  printf '#!/bin/sh\necho %s\n' "$speaker" > "$dir/bin/kefctl"
  # src 127.0.0.1 so the fake client reaches the server over loopback.
  printf '#!/bin/sh\necho "192.168.4.190 dev test src 127.0.0.1 uid 1000"\n' > "$dir/bin/ip"

  cat > "$dir/bin/pactl" <<EOF
#!/bin/sh
echo "\$(date +%s.%N) pactl \$*" >> "$dir/calls.log"
case "\$1" in
  load-module) echo 4242 ;;
esac
exit 0
EOF

  # Fails only while the toggle file exists, so a test can make casting start
  # working part-way through a run.
  cat > "$dir/bin/catt" <<EOF
#!/bin/sh
echo "\$(date +%s.%N) catt \$*" >> "$dir/calls.log"
for a in "\$@"; do
  if [ "\$a" = cast ]; then
    # A hang models catt's real failure mode: the plan records this same
    # pychromecast path blocking past 25s during investigation.
    [ -e "$dir/cast_hangs" ] && sleep 60
    [ -e "$dir/cast_fails" ] && exit 1
    exit 0
  fi
done
exit 0
EOF

  chmod +x "$dir/bin"/*
  sed "s|^export PATH=.*|export PATH=\"$dir/bin:/usr/bin:/bin\"|" \
    "$STORE/bin/kef-cast" > "$dir/kef-cast"
  chmod +x "$dir/kef-cast"
}

# Sets the variable NAMED by $1 to a fresh sandbox dir. It writes through a
# nameref rather than echoing, because `dir=$(new_sandbox)` would run this in a
# SUBSHELL and the SANDBOXES+=() registration would die with it — leaving every
# wrapper process and temp dir behind after the suite exits. Measured: 32 stray
# processes before this was fixed.
new_sandbox() {  # $1 = variable to set, $2 = "fail" to start with casting broken
  # __sb_dir, not dir: `local dir` here would SHADOW the caller's variable, and
  # `printf -v dir` would then assign to this function's copy and leave the
  # caller's unset. Under `set -u` that surfaces immediately; without it the
  # tests would silently operate on an empty path.
  local __outvar=$1 __sb_dir
  __sb_dir=$(mktemp -d "${TMPDIR:-/tmp}/kef-cast-test.XXXXXX")
  SANDBOXES+=("$__sb_dir")
  make_sandbox "$__sb_dir" "${3:-127.0.0.1}"
  [ "${2:-}" = fail ] && touch "$__sb_dir/cast_fails"
  printf -v "$__outvar" '%s' "$__sb_dir"
}

stopped_count() { grep -c 'catt .* stop' "$1/calls.log" 2>/dev/null | tr -d ' '; }
unloaded_count() { grep -c 'pactl unload-module' "$1/calls.log" 2>/dev/null | tr -d ' '; }

start_wrapper() {  # $1 dir, $2 port, $3 grace, [$4 give-up seconds]
  local dir=$1 port=$2 grace=$3 giveup=${4:-3600}
  KEF_CAST_PORT="$port" KEF_CAST_RECAST_AFTER="$grace" KEF_CAST_GIVE_UP="$giveup" \
    "$dir/kef-cast" > "$dir/out.log" 2>&1 &
  echo $! > "$dir/wrapper.pid"
}

wrapper_alive() { kill -0 "$(cat "$1/wrapper.pid" 2>/dev/null)" 2>/dev/null; }
cast_count() { grep -c 'catt .* cast ' "$1/calls.log" 2>/dev/null | tr -d ' '; }
stamped_lines() { grep -cE '[0-9]{2}:[0-9]{2}:[0-9]{2}' "$1/out.log" 2>/dev/null | tr -d ' '; }

# Inter-cast gaps in seconds, one per line, from the stub's timestamps.
cast_gaps() {
  grep 'catt .* cast ' "$1/calls.log" | awk '{print $1}' |
    awk 'NR>1 {printf "%.1f\n", $1 - prev} {prev = $1}'
}

wait_until() {  # $1 seconds, rest: condition
  local limit=$1; shift
  local end=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if eval "$@"; then return 0; fi
    sleep 0.4
  done
  return 1
}

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; return 1; }

# ---------------------------------------------------------------- reconnect
# A receiver attaches, then drops. The bridge must notice and cast again.
test_reconnect() {
  echo "reconnect: re-casts after the receiver drops"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 3

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup; log: $(cat "$dir/out.log")"; return 1; }

  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 3 >/dev/null 2>&1 \
    || { fail "fake client could not read the stream"; return 1; }
  # client has now closed — that is the drop

  wait_until 25 '[ "$(cast_count '"$dir"')" -ge 2 ]' \
    || { fail "no re-cast within 25s of the receiver dropping (casts=$(cast_count "$dir"))"; return 1; }

  pass "re-cast observed after drop"
}

# ------------------------------------------------------------- no-spurious
# While a receiver is happily attached, nothing may re-cast: a watchdog that
# fires on a healthy session would interrupt playback.
test_no_spurious() {
  echo "no-spurious: does not re-cast while a receiver stays attached"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 3

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 12 >/dev/null 2>&1
  local n; n=$(cast_count "$dir")
  [ "$n" -eq 1 ] || { fail "expected exactly 1 cast while attached, saw $n"; return 1; }
  pass "no spurious re-cast over 12s attached"
}

# ------------------------------------------------------------------ backoff
# The interval must GROW while casting fails and then STOP growing at the cap.
# Asserting only growth lets unbounded doubling through — after a few hours
# asleep the speaker would wake to a bridge waiting hours before its next try.
test_backoff() {
  echo "backoff: retry interval grows, then holds at the cap"
  local dir port grace cap; new_sandbox dir fail; port=$(free_port); grace=2; cap=$((grace * 4))
  start_wrapper "$dir" "$port" "$grace"

  wait_until 90 '[ "$(cast_count '"$dir"')" -ge 5 ]' \
    || { fail "expected >=5 cast attempts while failing, saw $(cast_count "$dir")"; return 1; }

  local gaps g1 g2 g3 g4
  gaps=$(cast_gaps "$dir")
  g1=$(echo "$gaps" | sed -n 1p); g2=$(echo "$gaps" | sed -n 2p)
  g3=$(echo "$gaps" | sed -n 3p); g4=$(echo "$gaps" | sed -n 4p)

  awk -v a="$g1" -v b="$g2" 'BEGIN { exit !(b > a) }' \
    || { fail "retry gaps did not grow: $g1 then $g2"; return 1; }
  # The cap: once at the ceiling the interval must stay there, and must never
  # exceed it. +1.5s of slack for the 1s tick and process scheduling.
  awk -v c="$g3" -v d="$g4" -v cap="$cap" 'BEGIN { exit !(c <= cap + 1.5 && d <= cap + 1.5) }' \
    || { fail "retry interval passed the ${cap}s cap: gaps $g1 $g2 $g3 $g4"; return 1; }
  awk -v c="$g3" -v d="$g4" 'BEGIN { exit !(d < c * 1.6) }' \
    || { fail "retry interval still doubling past the cap: $c then $d"; return 1; }
  pass "gaps $g1 $g2 $g3 $g4 grew then held at ${cap}s"
}

# -------------------------------------------------------------------- reset
# After failures have pushed the interval to the ceiling, a receiver attaching
# must reset it — otherwise the next drop in a flaky session waits the full cap
# instead of the grace period, repeatedly.
test_reset() {
  echo "reset: interval returns to the grace period once a receiver attaches"
  local dir port grace; new_sandbox dir fail; port=$(free_port); grace=2
  start_wrapper "$dir" "$port" "$grace"

  # Let failures push RETRY up to the 8s ceiling.
  wait_until 90 '[ "$(cast_count '"$dir"')" -ge 4 ]' \
    || { fail "casting never retried enough to grow the interval"; return 1; }

  rm -f "$dir/cast_fails"           # casting works again
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 4 >/dev/null 2>&1 \
    || { fail "fake client could not read the stream"; return 1; }
  # attached for 4s, then dropped

  local before after
  before=$(cast_count "$dir")
  # A reset interval re-casts within grace (+slack). A still-grown one waits 8s.
  if wait_until $((grace + 3)) '[ "$(cast_count '"$dir"')" -gt '"$before"' ]'; then
    after=$(cast_count "$dir")
    pass "re-cast within $((grace + 3))s of the drop (casts $before -> $after)"
  else
    fail "no re-cast within $((grace + 3))s of the drop — the interval did not reset on attach"
    return 1
  fi
}

# ------------------------------------------------------------------ logging
# "It constantly drops" has to become a timestamp series. Counting timestamped
# lines outright is not enough: the wrapper prints two at startup, so that
# assertion holds with every drop/recovery line deleted. Measure the GROWTH
# across a drop instead.
test_logging() {
  echo "logging: new timestamped lines appear for the drop and the recovery"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 3

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }
  sleep 1
  local baseline; baseline=$(stamped_lines "$dir")   # startup chatter

  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 3 >/dev/null 2>&1
  wait_until 25 '[ "$(cast_count '"$dir"')" -ge 2 ]' >/dev/null
  sleep 1

  local after grown; after=$(stamped_lines "$dir"); grown=$((after - baseline))
  [ "$grown" -ge 2 ] \
    || { fail "expected >=2 NEW timestamped lines across attach/drop/re-cast, saw $grown (baseline $baseline, after $after); log: $(cat "$dir/out.log")"; return 1; }

  # Counting new lines is not enough on its own: the re-cast events alone
  # satisfy it, so the attach and the drop could both go unlogged and this
  # would still pass. Measured doing exactly that. Demand evidence of each,
  # accepting any of the obvious wordings rather than pinning one phrasing.
  # Scope by TIMESTAMPED lines, not raw file lines: baseline is a match count,
  # and out.log also carries untimestamped startup chatter, so `tail -n +N`
  # would reach back into the startup block and let a future "connecting..."
  # banner satisfy the attach grep with the attach event deleted.
  local tail_log
  tail_log=$(grep -E '[0-9]{2}:[0-9]{2}:[0-9]{2}' "$dir/out.log" | tail -n +$((baseline + 1)))
  grep -qiE 'attach|connect' <<<"$tail_log" \
    || { fail "no timestamped line records the receiver ATTACHING; log after baseline: $tail_log"; return 1; }
  grep -qiE 'drop|detach|disconnect|gone|lost' <<<"$tail_log" \
    || { fail "no timestamped line records the receiver DROPPING; log after baseline: $tail_log"; return 1; }
  pass "$grown new timestamped lines, including the attach and the drop"
}

# ------------------------------------------------------------------ give-up
# A cast that never succeeds must not leave the stream server listening forever.
# The port is an unauthenticated capture endpoint open to the whole LAN, so
# "speaker is switched off" must not mean "microphone open until someone
# notices". Once a receiver HAS attached, the watchdog is free to retry forever.
test_give_up() {
  echo "give-up: exits and closes the port when no receiver ever attaches"
  local dir port; new_sandbox dir fail; port=$(free_port)
  start_wrapper "$dir" "$port" 2 6

  wait_until 40 '! wrapper_alive '"$dir" \
    || { fail "wrapper still running with no receiver ever attached — capture port left open"; return 1; }

  wait_until 10 '! python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex((\"127.0.0.1\", '"$port"')) == 0 else 1)
"' || { fail "wrapper exited but port $port is still accepting connections"; return 1; }

  pass "gave up and released the port"
}


# ----------------------------------------------------------- retry-forever
# The give-up rule has two halves and only one was ever tested. Once a receiver
# HAS attached, the bridge must keep retrying past the give-up deadline — that
# is the whole drop-recovery case. Deleting the latch kills a healthy session.
test_retry_forever() {
  echo "retry-forever: keeps retrying past the give-up deadline once a receiver has attached"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 2 4

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  # A real receiver attaches and then drops.
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 3 >/dev/null 2>&1 \
    || { fail "fake client could not read the stream"; return 1; }
  touch "$dir/cast_fails"     # and now nothing can reconnect

  # Well past GIVE_UP=4s. The wrapper must still be alive and still trying.
  sleep 9
  wrapper_alive "$dir" \
    || { fail "wrapper gave up despite a receiver having attached — a recovered session would be killed at GIVE_UP"; return 1; }
  pass "still alive and retrying 9s after a 4s give-up deadline"
}

# --------------------------------------------------------------- impostor
# The give-up latch must not be settable by any LAN host. serve.py counts EVERY
# GET, so if an attach alone latches it, one unauthenticated request re-opens
# the indefinitely-listening capture port that give-up exists to bound.
test_impostor() {
  echo "impostor: a non-speaker client must not disable the give-up rule"
  # The wrapper believes the speaker is 192.0.2.1 (TEST-NET-1); our client
  # connects from 127.0.0.1, so it is NOT the receiver.
  local dir port; new_sandbox dir "" 192.0.2.1; port=$(free_port)
  start_wrapper "$dir" "$port" 2 5

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  # Hold the impostor connection ACROSS the whole give-up deadline.
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 11 >/dev/null 2>&1 &
  local cpid=$!

  wait_until 30 '! wrapper_alive '"$dir" \
    || { kill $cpid 2>/dev/null; fail "wrapper never gave up — a stranger's GET disabled the rule and the capture port stays open"; return 1; }
  kill $cpid 2>/dev/null
  pass "gave up despite the impostor holding a connection"
}

# ------------------------------------------------------------- cast-hang
# catt is a blocking network call on a 1 Hz loop. The plan records this same
# path hanging past 25s. An unbounded call freezes the watchdog: no drain, no
# give-up check, no attach noticed, for as long as catt sulks.
test_cast_hang() {
  echo "cast-hang: a hanging catt does not freeze the watchdog"
  local dir port; new_sandbox dir; port=$(free_port)
  touch "$dir/cast_hangs"
  start_wrapper "$dir" "$port" 2

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never attempted the startup cast"; return 1; }
  # The startup cast is now hanging for 60s. Attach a receiver during it.
  sleep 2
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 20 >/dev/null 2>&1 &
  local cpid=$!

  # A time-bounded cast lets the loop resume and log the attach well inside 25s.
  if wait_until 25 'grep -qiE "attach|connect" '"$dir"'/out.log'; then
    kill $cpid 2>/dev/null
    pass "attach observed while a cast was hanging"
  else
    kill $cpid 2>/dev/null
    fail "watchdog blocked: no attach logged within 25s while catt hung — the cast call is not time-bounded"
    return 1
  fi
}

# --------------------------------------------------------- cleanup-contract
# The give-up path is a brand-new exit. The stubs already record every pactl and
# catt call; nothing read them until now.
test_cleanup_contract() {
  echo "cleanup-contract: give-up unloads the sink and does not stop a cast it never made"
  local dir port; new_sandbox dir fail; port=$(free_port)
  start_wrapper "$dir" "$port" 2 6

  wait_until 40 '! wrapper_alive '"$dir" \
    || { fail "wrapper never gave up"; return 1; }
  sleep 1

  [ "$(unloaded_count "$dir")" -ge 1 ] \
    || { fail "null sink leaked: no 'pactl unload-module' after the give-up exit"; return 1; }
  # Every cast failed, so CASTING was never set and stopping would be reaching
  # for a session this process does not own.
  [ "$(stopped_count "$dir")" -eq 0 ] \
    || { fail "issued 'catt stop' for a cast that was never accepted — the CASTING guard is broken"; return 1; }
  pass "sink unloaded, no stray catt stop"
}


# ------------------------------------------------------------- exit-status
# The watchdog loop replaced `wait "$SRVPID"`, which used to propagate the
# stream server's exit code. Falling off the end of the loop after a successful
# `event` line exits 0, so a crashed encoder now reads as a clean shutdown to
# anything supervising this process.
test_exit_status() {
  echo "exit-status: a dead stream server is not reported as a clean exit"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 3
  local wpid; wpid=$(cat "$dir/wrapper.pid")

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  # Kill the server the way a crash would, and see what the wrapper reports.
  local srv; srv=$(pgrep -P "$wpid" -f 'serve\.py' | head -1)
  [ -n "$srv" ] || { fail "could not find the stream server child of $wpid"; return 1; }
  kill -9 "$srv"

  local status=0
  wait "$wpid" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] \
    || { fail "wrapper exited 0 after its stream server was killed — a broken stream reads as a clean shutdown"; return 1; }
  pass "exited non-zero ($status) when the stream server died"
}


# -------------------------------------------------- stranger-blocks-recovery
# Recovery must key on the SPEAKER's presence, not the total client count. A
# stranger holding a connection keeps the total above zero, so if the total is
# what gates re-casting, the speaker can drop and the bridge stays silent for
# the life of the session while the capture port stays open.
test_stranger_blocks_recovery() {
  echo "stranger-blocks-recovery: a stranger's connection must not mask the speaker dropping"
  # 127.0.0.0/8 is all local: the speaker is 127.0.0.2, a stranger is 127.0.0.1.
  local dir port; new_sandbox dir "" 127.0.0.2; port=$(free_port)
  start_wrapper "$dir" "$port" 3

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  # A stranger attaches and stays for the whole test.
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 30 127.0.0.1 >/dev/null 2>&1 &
  local spid=$!
  sleep 1
  # The speaker attaches, then drops, while the stranger is still holding on.
  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 3 127.0.0.2 >/dev/null 2>&1
  local before; before=$(cast_count "$dir")

  if wait_until 20 '[ "$(cast_count '"$dir"')" -gt '"$before"' ]'; then
    kill $spid 2>/dev/null
    pass "re-cast after the speaker dropped, despite the stranger still attached"
  else
    kill $spid 2>/dev/null
    fail "no re-cast: the stranger's connection masked the speaker dropping (casts stuck at $before)"
    return 1
  fi
}

# ------------------------------------------------ timeout-counts-as-failed
# A cast that timed out was never accepted, so it must not be recorded as ours.
# If it is, teardown fires `catt stop` at a speaker we never got — killing
# whatever someone else was playing, which is what the CASTING guard prevents.
test_timeout_counts_as_failed() {
  echo "timeout-counts-as-failed: a timed-out cast is not recorded as an accepted one"
  local dir port; new_sandbox dir; port=$(free_port)
  touch "$dir/cast_hangs"          # every cast hangs, so every cast times out
  start_wrapper "$dir" "$port" 2

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never attempted a cast"; return 1; }
  # Let the bound expire and the loop carry on past it.
  wait_until 60 '[ "$(cast_count '"$dir"')" -ge 2 ]' \
    || { fail "cast never timed out and retried — the call is not bounded"; return 1; }

  kill "$(cat "$dir/wrapper.pid")" 2>/dev/null
  wait_until 15 '! wrapper_alive '"$dir" || true
  sleep 1
  [ "$(stopped_count "$dir")" -eq 0 ] \
    || { fail "teardown issued 'catt stop' after only timed-out casts — a timeout was recorded as accepted"; return 1; }
  pass "no stray catt stop after timed-out casts"
}

# ------------------------------------------------------- teardown-after-cast
# The other half of the cleanup contract: a session that DID cast must, on
# signal, stop exactly once and unload its sink. `CLEANED` exists so INT then
# EXIT does not stop twice.
test_teardown_after_cast() {
  echo "teardown-after-cast: a live session stops once and unloads its sink"
  local dir port; new_sandbox dir; port=$(free_port)
  start_wrapper "$dir" "$port" 3

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }
  local wpid; wpid=$(cat "$dir/wrapper.pid")
  kill -INT "$wpid" 2>/dev/null
  wait_until 15 '! wrapper_alive '"$dir" \
    || { fail "wrapper did not exit on INT"; return 1; }
  local status=0; wait "$wpid" 2>/dev/null || status=$?
  sleep 1

  local stops unloads; stops=$(stopped_count "$dir"); unloads=$(unloaded_count "$dir")
  [ "$stops" -eq 1 ] \
    || { fail "expected exactly 1 'catt stop' on teardown after a live cast, saw $stops"; return 1; }
  # Exactly one, not "at least one": the CLEANED guard exists so INT-then-EXIT
  # cleans once, and >=1 would pass with the guard deleted.
  [ "$unloads" -eq 1 ] \
    || { fail "expected exactly 1 'pactl unload-module' on teardown, saw $unloads (CLEANED guard?)"; return 1; }
  [ "$status" -ne 0 ] \
    || { fail "exited 0 after a signal; a signalled shutdown must not look like success"; return 1; }
  pass "stopped once, unloaded once, exited $status"
}


# ------------------------------------------------------------------ defaults
# The shipped defaults, with no environment overrides. Both numbers here were
# chosen from measurements against the real speaker, not from taste:
#   - 15s of silence lost the listener before recovery finished (observed).
#   - 192k had no headroom when the link degraded; 96k roughly doubled the
#     uptime between drops (15m05s vs 7m48s / 4m21s).
test_defaults() {
  echo "defaults: 3s grace and 96k bitrate without any env override"
  local dir port; new_sandbox dir; port=$(free_port)
  # Deliberately NOT passing KEF_CAST_RECAST_AFTER or KEF_CAST_BITRATE.
  KEF_CAST_PORT="$port" "$dir/kef-cast" > "$dir/out.log" 2>&1 &
  echo $! > "$dir/wrapper.pid"

  wait_until 20 '[ "$(cast_count '"$dir"')" -ge 1 ]' \
    || { fail "wrapper never cast at startup"; return 1; }

  python3 "$HERE/fake_client.py" 127.0.0.1 "$port" 4 >/dev/null 2>&1 &
  local cpid=$!
  sleep 2
  local srv enc
  srv=$(pgrep -P "$(cat "$dir/wrapper.pid")" -f 'serve' | head -1)
  enc=$(pgrep -P "$srv" -a 2>/dev/null | head -1)
  kill $cpid 2>/dev/null
  case "$enc" in
    *"-b:a 96k"*) ;;
    *) fail "encoder is not at the 96k default: $enc"; return 1 ;;
  esac

  # The client is gone; a 3s default must re-cast well inside 8s.
  local before; before=$(cast_count "$dir")
  wait_until 8 '[ "$(cast_count '"$dir"')" -gt '"$before"' ]' \
    || { fail "no re-cast within 8s of the drop — the grace default is not 3s"; return 1; }
  pass "96k encoder and a re-cast inside 8s, both from defaults"
}

main() {
  STORE=$(build_wrapper)
  if [ -z "$STORE" ] || [ ! -x "$STORE/bin/kef-cast" ]; then
    echo "could not build kef-cast — cannot run the suite" >&2
    exit 127
  fi

  local rc=0
  case "${1:-all}" in
    reconnect)   test_reconnect   || rc=1 ;;
    no-spurious) test_no_spurious || rc=1 ;;
    backoff)     test_backoff     || rc=1 ;;
    reset)       test_reset       || rc=1 ;;
    logging)     test_logging     || rc=1 ;;
    give-up)     test_give_up     || rc=1 ;;
    retry-forever) test_retry_forever || rc=1 ;;
    impostor)    test_impostor    || rc=1 ;;
    cast-hang)   test_cast_hang   || rc=1 ;;
    cleanup)     test_cleanup_contract || rc=1 ;;
    exit-status) test_exit_status  || rc=1 ;;
    stranger)    test_stranger_blocks_recovery || rc=1 ;;
    timeout-failed) test_timeout_counts_as_failed || rc=1 ;;
    teardown)    test_teardown_after_cast || rc=1 ;;
    defaults)    test_defaults    || rc=1 ;;
    core)
      test_reconnect   || rc=1
      test_no_spurious || rc=1
      test_backoff     || rc=1
      test_reset       || rc=1
      test_logging     || rc=1
      test_teardown_after_cast || rc=1
      ;;
    watchdog)
      test_give_up     || rc=1
      test_retry_forever || rc=1
      test_impostor    || rc=1
      test_cleanup_contract || rc=1
      test_exit_status || rc=1
      test_defaults    || rc=1
      ;;
    recovery)
      test_cast_hang   || rc=1
      test_stranger_blocks_recovery || rc=1
      test_timeout_counts_as_failed || rc=1
      ;;
    all)
      test_reconnect   || rc=1
      test_no_spurious || rc=1
      test_backoff     || rc=1
      test_reset       || rc=1
      test_logging     || rc=1
      test_give_up     || rc=1
      test_retry_forever || rc=1
      test_impostor    || rc=1
      test_cast_hang   || rc=1
      test_cleanup_contract || rc=1
      test_exit_status || rc=1
      test_stranger_blocks_recovery || rc=1
      test_timeout_counts_as_failed || rc=1
      test_teardown_after_cast || rc=1
      test_defaults    || rc=1
      ;;
    *) echo "unknown test: $1" >&2; exit 2 ;;
  esac

  [ $rc -eq 0 ] && echo "PASS" || echo "FAIL"
  exit $rc
}

main "$@"
