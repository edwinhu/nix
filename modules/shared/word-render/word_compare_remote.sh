#!/usr/bin/env bash
# word_compare_remote.sh — Word redline (Application.CompareDocuments) in the
# Windows guest, over SSH. Companion to word_render_remote.sh and built the same
# way: the guest-side PowerShell runs through a scheduled task with /IT, because
# Word COM does not fully initialize in OpenSSH's non-interactive window station.
#
# Word diffs footnote-internal text; LibreOffice does not. On a footnote-heavy
# manuscript that is the reason this path exists.
#
#   WINVM_SSH=word@winvm ./word_compare_remote.sh base.docx rev.docx out.docx [stats.txt]
#
# The stats file records Word's own revision counts, footnote story included.
set -euo pipefail

BASE="${1:?usage: word_compare_remote.sh <base.docx> <rev.docx> <out.docx> [stats.txt]}"
REV="${2:?}"
OUT="${3:?}"
STATS="${4:-${OUT%.docx}.stats.txt}"

: "${WINVM_SSH:=word@winvm}"
: "${WINVM_DIR:=C:/Users/word/render}"
# NOT WINVM_SCRIPT: that names the guest-side RENDERER and is exported
# session-wide by the nix module, so reusing it here would point compare at
# render_docx.ps1.
: "${WINVM_COMPARE_SCRIPT:=C:/Users/word/compare_docx.ps1}"
: "${WINVM_COMPARE_PS1:=$(dirname "$0")/compare_docx.ps1}"

J_BASE="$WINVM_DIR/_cmp_base.docx"
J_REV="$WINVM_DIR/_cmp_rev.docx"
J_OUT="$WINVM_DIR/_cmp_out.docx"
J_STATS="$WINVM_DIR/_cmp_stats.txt"
TASK="wcompare"

# The guest copy is refreshed every run, so the deployed script is always the
# one that executes (home-manager stows it as a symlink; scp follows it).
scp -q "$WINVM_COMPARE_PS1" "$WINVM_SSH:$WINVM_COMPARE_SCRIPT"
scp -q "$BASE" "$WINVM_SSH:$J_BASE"
scp -q "$REV"  "$WINVM_SSH:$J_REV"

ssh "$WINVM_SSH" "schtasks /create /tn $TASK /tr \"powershell -NoProfile -ExecutionPolicy Bypass -File $WINVM_COMPARE_SCRIPT -Base $J_BASE -Rev $J_REV -Out $J_OUT -Stats $J_STATS\" /sc once /st 00:00 /rl highest /it /f >NUL" || true
# Remove-Item exits 1 when the file is absent even under SilentlyContinue; the
# trailing `exit 0` keeps set -e happy.
ssh "$WINVM_SSH" "powershell -NoProfile -Command \"Remove-Item -Force -ErrorAction SilentlyContinue '$J_OUT','$J_STATS'; exit 0\"" || true
ssh "$WINVM_SSH" "schtasks /run /tn $TASK >NUL" || true

# Wait for the task to leave Running AND drop the output (guard against reading
# Status before the task has spun up). ~5 min ceiling: compare is slower than
# render on a full article.
ok=""
for _ in $(seq 1 150); do
  sleep 2
  st="$(ssh "$WINVM_SSH" "schtasks /query /tn $TASK /fo list" 2>/dev/null | tr -d '\r' | awk -F: '/Status/{gsub(/^[ \t]+/,"",$2);print $2}')"
  have="$(ssh "$WINVM_SSH" "powershell -NoProfile -Command \"Test-Path '$J_OUT'\"" 2>/dev/null | tr -d '\r')"
  if [ "$st" != "Running" ] && [ "$have" = "True" ]; then ok=1; break; fi
done
[ -n "$ok" ] || { echo "word-compare: guest compare did not complete (no $J_OUT)" >&2; exit 1; }

scp -q "$WINVM_SSH:$J_OUT" "$OUT"
scp -q "$WINVM_SSH:$J_STATS" "$STATS" || true
echo "wrote $OUT"
