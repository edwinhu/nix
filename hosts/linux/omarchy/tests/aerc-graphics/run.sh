#!/usr/bin/env bash
# Contract test for aerc-graphics-probe.sh. Asserts only that the probe RUNS and
# REPORTS -- never which value it reports. apc_chunks=0 and apc_chunks=7 both pass.
#
# The probe is handed a PRIVATE TMPDIR so the stray-dir and stray-process checks
# can only ever see this suite's own runs: scanning the shared /tmp made the
# result depend on whoever else was running the probe at the same moment.
set -u

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../.." && pwd)
probe="$repo_root/hosts/linux/omarchy/files/aerc-graphics-probe.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$probe" ] || fail "probe not found: $probe"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/aerc-gfx-suite.XXXXXX") || fail "cannot make sandbox"
trap 'rm -rf "$sandbox"' EXIT
probe_tmp=$sandbox/tmp   # the only place the probe may leave anything
evidence=$sandbox/ev     # written by the suite's request, not probe scratch
mkdir -p "$probe_tmp" "$evidence"

stray_dirs() { find "$probe_tmp" -mindepth 1 -maxdepth 1 -print 2>/dev/null; }
stray_procs() {
  local pid
  for pid in $(pgrep -x aerc 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qF "$probe_tmp"; then
      echo "$pid"
    fi
  done
}

run_probe() { # $1 = label; echoes the reported N
  local out rc hits total n ev
  ev=$evidence/${1// /-}
  out=$(TMPDIR="$probe_tmp" AERC_GFX_PROBE_EVIDENCE="$ev" timeout 180 bash "$probe" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$1: probe exited $rc"

  hits=$(printf '%s\n' "$out" | grep -c '^apc_chunks=[0-9][0-9]*$')
  [ "$hits" -eq 1 ] || fail "$1: expected exactly one 'apc_chunks=<N>' line, got $hits. Output was:
$out"

  # the report must be the whole of stdout: no extra chatter to hide a stub behind
  total=$(printf '%s\n' "$out" | grep -c .)
  [ "$total" -eq 1 ] || fail "$1: stdout must be the single apc_chunks line, got $total lines:
$out"

  # A probe that printed the right line without doing anything would satisfy
  # everything above. These check the raw pty capture instead, which only a real
  # aerc session can produce -- the suite never takes the probe's word for it.
  [ -s "$ev/capture.bin" ] || fail "$1: no pty capture: nothing was run"
  local bytes
  bytes=$(wc -c < "$ev/capture.bin")
  [ "$bytes" -gt 4096 ] || fail "$1: pty capture is only $bytes bytes; aerc did not draw a UI"
  grep -qa 'PROBEMSG' "$ev/capture.bin" ||
    fail "$1: the fixture subject never appears in the capture; aerc never drew the message list"
  grep -qa 'PROBE-FILTER-RAN' "$ev/capture.bin" ||
    fail "$1: the text/html filter's output never reached the wire; the viewer was not measured"
  grep -q '^kitty_query_answered=1$' "$ev/caps.txt" ||
    fail "$1: aerc's kitty capability query was never answered; a count would measure the harness"
  grep -q '^control_apc_chunks=[1-9]' "$ev/counts.txt" ||
    fail "$1: the plain-pty positive control found no APC; the counter itself is broken"

  n=$(printf '%s\n' "$out" | sed -n 's/^apc_chunks=//p')
  # the reported number must be the one derived from that capture
  grep -q "^apc_chunks=$n\$" "$ev/counts.txt" ||
    fail "$1: reported apc_chunks=$n does not match the capture-derived count"
  printf '%s' "$n"
}

# run_probe runs in a command substitution, so its fail() only exits that
# subshell -- the status must be checked here or a failed run is swallowed.
n1=$(run_probe "run 1") || exit 1
n2=$(run_probe "run 2") || exit 1
[ -n "$n1" ] && [ -n "$n2" ] || fail "probe reported no number"

[ "$n1" = "$n2" ] || fail "probe is not reproducible: run 1 said $n1, run 2 said $n2"

leftover=$(stray_dirs)
[ -z "$leftover" ] || fail "probe left temp directories behind:
$leftover"

procs=$(stray_procs)
[ -z "$procs" ] || fail "probe left aerc processes behind: $procs"

echo "PASS: probe reports apc_chunks=$n1 reproducibly, no strays"
