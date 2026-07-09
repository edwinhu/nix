#!/usr/bin/env bash
# start-tpm.sh — TPM 2.0 emulator socket for the Win11 guest (a hard Win11
# requirement). Run in the background before start-winvm.sh:
#   ./start-tpm.sh &
set -euo pipefail
VMDIR="${WINVM_DATA_DIR:-$HOME/.local/share/winvm}"
mkdir -p "$VMDIR/tpm"
exec swtpm socket \
  --tpmstate dir="$VMDIR/tpm" \
  --ctrl type=unixio,path="$VMDIR/tpm/swtpm-sock" \
  --tpm2 --log level=1
