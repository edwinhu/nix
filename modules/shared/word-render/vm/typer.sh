#!/usr/bin/env bash
# typer.sh — type an arbitrary string into the guest via the QEMU monitor
# `sendkey` command (works headlessly, independent of host window focus). Used to
# drive the one non-scriptable install step — the UEFI "press any key to boot
# from CD" prompt and the one-time UEFI-shell bootloader launch — and any other
# blind console work. Read the screen back with:
#   printf 'screendump %s/screen.ppm\n' "$VMDIR" | nc -U -w1 "$VMDIR/monitor.sock"
#
#   ./typer.sh 'some command'      # types it; caller sends Enter via sendkey ret
set -euo pipefail
export LC_ALL=C
VMDIR="${WINVM_DATA_DIR:-$HOME/.local/share/winvm}"
mon(){ printf '%s\n' "$1" | nc -U -w1 "$VMDIR/monitor.sock" >/dev/null 2>&1; }
S="$1"
for (( i=0; i<${#S}; i++ )); do
  c="${S:$i:1}"; key=""
  case "$c" in
    [A-Z]) key="shift-$(printf '%s' "$c" | tr 'A-Z' 'a-z')" ;;
    [a-z]) key="$c" ;;
    [0-9]) key="$c" ;;
    " ") key="spc" ;;
    "-") key="minus" ;;  "_") key="shift-minus" ;;
    "=") key="equal" ;;  "+") key="shift-equal" ;;
    "\\") key="backslash" ;; "|") key="shift-backslash" ;;
    ";") key="semicolon" ;; ":") key="shift-semicolon" ;;
    "'") key="apostrophe" ;; "\"") key="shift-apostrophe" ;;
    ",") key="comma" ;; "<") key="shift-comma" ;;
    ".") key="dot" ;; ">") key="shift-dot" ;;
    "/") key="slash" ;; "?") key="shift-slash" ;;
    "[") key="bracket_left" ;; "{") key="shift-bracket_left" ;;
    "]") key="bracket_right" ;; "}") key="shift-bracket_right" ;;
    "!") key="shift-1" ;; "@") key="shift-2" ;; "#") key="shift-3" ;;
    "\$") key="shift-4" ;; "%") key="shift-5" ;; "^") key="shift-6" ;;
    "&") key="shift-7" ;; "*") key="shift-8" ;; "(") key="shift-9" ;; ")") key="shift-0" ;;
    "\`") key="grave_accent" ;; "~") key="shift-grave_accent" ;;
  esac
  [ -n "$key" ] && mon "sendkey $key"
  sleep 0.09
done
