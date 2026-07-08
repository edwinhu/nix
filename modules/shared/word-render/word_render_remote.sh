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

base="$(basename "$IN")"
stem="${base%.*}"

# Ship the docx in, render, pull the PDF back. Forward-slash Windows paths are
# accepted by both Word COM and OpenSSH's default shell.
scp -q "$IN" "$WINVM_SSH:$WINVM_DIR/$base"
ssh "$WINVM_SSH" "powershell -NoProfile -ExecutionPolicy Bypass -File '$WINVM_SCRIPT' -In '$WINVM_DIR/$base' -Out '$WINVM_DIR/$stem.pdf'"
scp -q "$WINVM_SSH:$WINVM_DIR/$stem.pdf" "$OUT"

echo "wrote $OUT"
