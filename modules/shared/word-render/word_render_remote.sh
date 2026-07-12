#!/usr/bin/env bash
# word_render_remote.sh — render a docx to PDF using a real Word engine running
# in a Windows guest, over SSH. Portable across hypervisors: works with the VM
# on this Mac (Parallels/UTM) and, unchanged, on a Linux KVM host later.
# Only WINVM_SSH differs between environments.
#
#   WINVM_SSH=word@winvm ./word_render_remote.sh draft.docx [draft.pdf]
#
set -euo pipefail

IN="${1:?usage: word_render_remote.sh <in.docx> [out.pdf]}"
OUT="${2:-${IN%.*}.pdf}"

: "${WINVM_SSH:=word@winvm}"                 # user@host of the Windows guest
: "${WINVM_DIR:=C:/Users/word/render}"       # scratch dir inside the guest
: "${WINVM_SCRIPT:=C:/Users/word/render_docx.ps1}"

# Word COM only fully initializes in an INTERACTIVE desktop session. A plain
# `ssh winvm powershell -File render_docx.ps1` runs in OpenSSH's non-interactive
# window station, where `Word.Application` is created but `.Documents` is null and
# the render dies with "cannot call a method on a null-valued expression". So we
# drive the render through a scheduled task with /IT, which executes in the
# autologon desktop session where COM works. Fixed `_job.*` names keep the task
# command constant (no per-file quoting through cmd->schtasks->powershell).
JOB_IN="$WINVM_DIR/_job.docx"
JOB_OUT="$WINVM_DIR/_job.pdf"
TASK="wrender"

scp -q "$IN" "$WINVM_SSH:$JOB_IN"

# (Re)create the task and clear any stale output, then fire it. All Windows paths
# are forward-slash (accepted by PowerShell -File and Word COM); file removal uses
# PowerShell (cmd's del mis-reads '/' as a switch).
ssh "$WINVM_SSH" "schtasks /create /tn $TASK /tr \"powershell -NoProfile -ExecutionPolicy Bypass -File $WINVM_SCRIPT -In $JOB_IN -Out $JOB_OUT\" /sc once /st 00:00 /rl highest /it /f >NUL" || true
# Remove-Item exits 1 when the file is absent (PS sets LASTEXITCODE even under
# SilentlyContinue); the trailing `exit 0` keeps set -e happy. Non-critical.
ssh "$WINVM_SSH" "powershell -NoProfile -Command \"Remove-Item -Force -ErrorAction SilentlyContinue '$JOB_OUT'; exit 0\"" || true
ssh "$WINVM_SSH" "schtasks /run /tn $TASK >NUL" || true

# Wait for the task to leave the Running state AND drop the PDF (guard against
# reading Status before the task has spun up). ~4 min ceiling.
ok=""
for _ in $(seq 1 120); do
  sleep 2
  st="$(ssh "$WINVM_SSH" "schtasks /query /tn $TASK /fo list" 2>/dev/null | tr -d '\r' | awk -F: '/Status/{gsub(/^[ \t]+/,"",$2);print $2}')"
  have="$(ssh "$WINVM_SSH" "powershell -NoProfile -Command \"Test-Path '$JOB_OUT'\"" 2>/dev/null | tr -d '\r')"
  if [ "$st" != "Running" ] && [ "$have" = "True" ]; then ok=1; break; fi
done
[ -n "$ok" ] || { echo "word-render: guest render did not complete (no $JOB_OUT)" >&2; exit 1; }

scp -q "$WINVM_SSH:$JOB_OUT" "$OUT"
echo "wrote $OUT"
