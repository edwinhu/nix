#!/usr/bin/env bash
# Behavioural contract for record-scroll.sh's tap-latency path.
#
# It EXECUTES the block against stubbed externals and asserts what actually happened -- ordering,
# exit code, verdict.json contents -- rather than grepping the source for tokens. A token grep
# passes when the recorder is started after the taps, when the daemon shutdown is deleted, or when
# the JSON keys appear in a comment; all three are silent measurement failures.
#
# Nothing here touches the real desktop: hyprctl, herdr, gpu-screen-recorder and terminal-browser
# are stubs on PATH, and the "recording" is a real 2-second mp4 built by ffmpeg with a known cut.
#
# Run: bash .claude/skills/aerc-scroll-gif/tests/test_record_scroll.sh
# Exit 0 all assertions pass, 1 a contract assertion failed, 2 the suite could not run.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
SCRIPTS="$HERE/../scripts"
SCRIPT="$SCRIPTS/record-scroll.sh"
REPO=$(cd -- "$HERE/../../../.." && pwd)
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "ffmpeg required" >&2; exit 2; }

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAILED=1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"; mkdir -p "$OUT" "$WORK/bin"
ORDER="$WORK/order.log"          # every stubbed external appends here, in call order

# A real recording whose cuts land AFTER the taps, so judge-pixels.py has honest pixels to measure.
# The block taps at roughly REC_START+1.5 s and +3.0 s (one 1.5 s settle, then 1.5 s per tap), so
# cuts at 2.0 s and 3.5 s make each tap measure ~500 ms. Cuts before the first tap would correctly
# measure "none", which tests the judge's window rather than the harness's wiring.
ffmpeg -y -v error -f lavfi -i color=c=black:s=320x240:r=60:d=2 \
                   -f lavfi -i color=c=white:s=320x240:r=60:d=1.5 \
                   -f lavfi -i color=c=black:s=320x240:r=60:d=1.5 \
  -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0[out]" -map "[out]" -pix_fmt yuv420p "$WORK/ref.mp4" \
  >/dev/null 2>&1 || { echo "could not build the reference video" >&2; exit 2; }

cat > "$WORK/bin/gpu-screen-recorder" <<STUB
#!/usr/bin/env bash
# A background job in a non-interactive shell inherits SIGINT as ignored, and bash cannot trap a
# signal that was ignored on entry -- so the script's \`kill -INT\` may never arrive here and
# \`wait\` would block forever. The trap is kept for the case where it does arrive; the deadline is
# what guarantees this stub terminates. Either way "recorder-stop" is recorded on the way out.
echo "recorder-start" >> "$ORDER"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
cp "$WORK/ref.mp4" "\$out"
stop() { echo "recorder-stop" >> "$ORDER"; exit 0; }
trap stop INT TERM
for _ in \$(seq 1 60); do sleep 0.2; done
stop
STUB
cat > "$WORK/bin/terminal-browser" <<STUB
#!/usr/bin/env bash
echo "tb-\$1" >> "$ORDER"
exit 0
STUB
cat > "$WORK/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1          # no daemon is ever running, so the wait loop falls straight through
STUB
cat > "$WORK/bin/hyprctl" <<STUB
#!/usr/bin/env bash
echo "tap" >> "$ORDER"
exit 0
STUB
chmod +x "$WORK/bin"/*
# terminal-browser is called by absolute path, so shadow that path too.
TB_DIR="$WORK/tbhome/.local/share/terminal-browser/app/bin"; mkdir -p "$TB_DIR"
cp "$WORK/bin/terminal-browser" "$TB_DIR/terminal-browser"

echo "record-scroll.sh tap-latency behavioural contract"

if ! bash -n "$SCRIPT" 2>/dev/null; then
  fail "bash -n parses the script" "$(bash -n "$SCRIPT" 2>&1 | head -3)"
  echo "record-scroll.sh: contract assertions FAILED" >&2; exit 1
fi
pass "bash -n parses the script"

# Execute ONLY the tap-latency block, with the surrounding harness stubbed. Extracting the block
# keeps the desktop setup (ghostty, herdr session, aerc) out of a headless test while still running
# the real code under test, including its real calls to judge-pixels.py.
sed -n '/^if \[ "\$INPUT" = tap-latency \]/,/^fi$/p' "$SCRIPT" > "$WORK/block.sh"
[ -s "$WORK/block.sh" ] || { echo "could not extract the tap-latency block" >&2; exit 2; }

cat > "$WORK/run.sh" <<DRIVER
set -uo pipefail
export PATH="$WORK/bin:\$PATH"
export HOME="$WORK/tbhome"
INPUT=tap-latency
OUT="$OUT"
REPORT="$OUT/report.md"
VERDICT_JSON=1
TEST_ADDR=0xdead
TEST_GEO=100x100+0+0
TAPS_N=2
SECONDS=0
log() { printf '%s\n' "\$*" >> "\$REPORT"; }
fail() { echo "HARNESS-FAIL: \$*" >> "$ORDER"; exit 3; }
hl_key() { hyprctl dispatch "\$@" >/dev/null 2>&1; sleep 0.05; }
# The block resolves judge-pixels.py relative to \$0, so \$0 must look like the real script.
set --
DRIVER
cat "$WORK/block.sh" >> "$WORK/run.sh"
# The block resolves its judges as "$(dirname "$(readlink -f "$0")")/judge-*.py", and $0 is this
# driver -- so the REAL judges are linked beside it. Copying them would test a stale duplicate.
ln -sf "$SCRIPTS/judge-pixels.py" "$WORK/judge-pixels.py"
ln -sf "$SCRIPTS/judge-taps.py" "$WORK/judge-taps.py"

( cd "$SCRIPTS" && bash "$WORK/run.sh" ) >"$WORK/stdout.txt" 2>"$WORK/stderr.txt"
RUN_EXIT=$?

if grep -q 'HARNESS-FAIL' "$ORDER" 2>/dev/null; then
  fail "the tap-latency block runs to completion" "$(grep HARNESS-FAIL "$ORDER" | head -2)"
fi

order=$(tr '\n' ' ' < "$ORDER" 2>/dev/null)

# 1. The daemon is shut down, and BEFORE the recorder starts -- a stale shared daemon is what makes
#    the pixel writer invisible, and shutting it down after the fact measures the wrong process.
if printf '%s' "$order" | grep -q 'tb-shutdown'; then
  if [[ "$order" == *tb-shutdown*recorder-start* ]]; then
    pass "the terminal-browser daemon is shut down before recording"
  else
    fail "the terminal-browser daemon is shut down before recording" "call order was: $order"
  fi
else
  fail "the terminal-browser daemon is shut down before recording" "no shutdown was ever called; order: $order"
fi

# 2. The recorder is running BEFORE the taps. Starting it afterwards yields a video in which the
#    tap's own repaint has already happened, so every tap measures 'none' or noise.
if [[ "$order" == *recorder-start*tap* ]]; then
  pass "the recorder starts before the first tap"
else
  fail "the recorder starts before the first tap" "call order was: $order"
fi

# 3. The recorder is stopped before the judge reads the file, or the mp4 is still being written.
if [[ "$order" == *tap*recorder-stop* ]]; then
  pass "the recorder is stopped after the taps"
else
  fail "the recorder is stopped after the taps" "call order was: $order"
fi

# 4. The pixel judge actually produced a measurement from the recording.
if [ -s "$OUT/taps.txt" ] && grep -q 'median key→frame ms:' "$OUT/taps.txt"; then
  pass "judge-pixels.py measured the recording"
else
  fail "judge-pixels.py measured the recording" \
       "no median line in $OUT/taps.txt: $(head -3 "$OUT/taps.txt" 2>/dev/null)"
fi

# 5. verdict.json carries both metrics, and the PIXEL judge owns verdict/exit/medianMs. The
#    announce* fields are null here because no trace exists -- which is the plain-surface shape.
if [ -s "$OUT/verdict.json" ]; then
  missing=""
  for key in verdict exit medianMs perTapMs announceMedianMs announcePerTapMs; do
    python3 -c "import json,sys; d=json.load(open('$OUT/verdict.json')); sys.exit(0 if '$key' in d else 1)" \
      || missing="$missing $key"
  done
  if [ -z "$missing" ]; then
    pass "verdict.json carries both metrics"
  else
    fail "verdict.json carries both metrics" "missing keys:$missing"
  fi
  if python3 -c "
import json,sys
d=json.load(open('$OUT/verdict.json'))
sys.exit(0 if d.get('announceMedianMs') is None else 1)"; then
    pass "the announcement metric is null when no trace exists"
  else
    fail "the announcement metric is null when no trace exists" \
         "announceMedianMs should be null without a trace: $(cat "$OUT/verdict.json")"
  fi
  if python3 -c "
import json,sys
d=json.load(open('$OUT/verdict.json'))
sys.exit(0 if isinstance(d.get('medianMs'), int) and d.get('exit') == $RUN_EXIT else 1)"; then
    pass "the pixel judge owns verdict, exit and medianMs"
  else
    fail "the pixel judge owns verdict, exit and medianMs" \
         "exit was $RUN_EXIT, verdict.json says: $(cat "$OUT/verdict.json")"
  fi
else
  fail "verdict.json carries both metrics" "no verdict.json was written (run exit $RUN_EXIT)"
  fail "the announcement metric is null when no trace exists" "no verdict.json"
  fail "the pixel judge owns verdict, exit and medianMs" "no verdict.json"
fi

# 6. Scope: the other inputs are untouched. Compared against the staged baseline, because the
#    instrument was force-staged for this work and HEAD does not carry it.
baseline=""
rel=".claude/skills/aerc-scroll-gif/scripts/record-scroll.sh"
if git -C "$REPO" show ":$rel" >/dev/null 2>&1; then
  baseline=$(git -C "$REPO" show ":$rel")
elif git -C "$REPO" show "HEAD:$rel" >/dev/null 2>&1; then
  baseline=$(git -C "$REPO" show "HEAD:$rel")
fi
if [ -n "$baseline" ]; then
  for branch in egress 'hold / keys'; do
    case "$branch" in
      egress) pat='/^if \[ "\$INPUT" = egress \]/,/^fi$/p' ;;
      *)      pat='/^# --- hold \/ keys/,$p' ;;
    esac
    now=$(sed -n "$pat" "$SCRIPT")
    was=$(printf '%s\n' "$baseline" | sed -n "$pat")
    if [ -z "$was" ]; then
      fail "the $branch branch is unchanged" "could not extract it from the baseline; the guard would be vacuous"
    elif [ "$now" = "$was" ]; then
      pass "the $branch branch is unchanged"
    else
      fail "the $branch branch is unchanged" "that code path was modified; it is out of scope for this run"
    fi
  done
else
  fail "the other input branches are unchanged" "no staged or committed baseline to compare against"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "record-scroll.sh: all behavioural contract assertions pass"
  exit 0
fi
echo "record-scroll.sh: contract assertions FAILED" >&2
exit 1
