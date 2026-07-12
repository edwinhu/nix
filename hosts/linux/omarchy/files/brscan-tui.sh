# brscan-tui — interactive front-end for the Brother DS-740D (charmbracelet/gum).
# Picks scan options, runs the scan with a spinner, offers to open the result.
# Tools (gum, brscan, brscan-pdf, xdg-open) come from writeShellApplication's
# runtimeInputs. `set -euo pipefail` is prepended by writeShellApplication.

hr() { gum style --border rounded --padding "0 2" --border-foreground 212 "$@"; }
err() { gum style --foreground 196 "$@"; }
ok() { gum style --foreground 82 "$@"; }

hr "󰚫  Brother DS-740D — Scan"

if ! brscan -L 2>/dev/null | grep -q 'brother5:'; then
  err "✗ Scanner not found. Wake it (unplug/replug — it's bus-powered) and retry."
  exit 1
fi

mode=$(gum choose --header "Color mode:" \
  "24bit Color[Fast]" "True Gray" "Black & White" "Gray[Error Diffusion]")
res=$(gum choose --header "Resolution (dpi):" 300 200 150 400 600 1200)
sides=$(gum choose --header "Sides:" "Single-sided" "Duplex (both sides)")
fmt=$(gum choose --header "Output format:" PDF PNG JPEG TIFF)

case "$fmt" in
  PDF)  ext=pdf ;;
  PNG)  sfmt=png;  ext=png ;;
  JPEG) sfmt=jpeg; ext=jpg ;;
  TIFF) sfmt=tiff; ext=tiff ;;
esac

out=$(gum input --header "Save as:" --value "$HOME/scan-$(date +%Y%m%d-%H%M%S).$ext")
[ -n "$out" ] || exit 1

dup=""
[ "$sides" = "Duplex (both sides)" ] && dup=1

if [ "$fmt" = PDF ]; then
  export SCAN_MODE="$mode" SCAN_DPI="$res" SCAN_DUPLEX="$dup"
  if ! gum spin --spinner dot --show-output --title "Scanning to PDF…" -- brscan-pdf "$out"; then
    err "✗ Scan failed (feeder empty or jam?)"; exit 1
  fi
else
  src="Automatic Document Feeder(left aligned)"
  [ -n "$dup" ] && src="Automatic Document Feeder(left aligned,Duplex)"
  if ! gum spin --spinner dot --title "Scanning…" -- \
      brscan --source "$src" --mode "$mode" --resolution "$res" --format="$sfmt" -o "$out"; then
    err "✗ Scan failed"; exit 1
  fi
fi

ok "✓ Saved: $out"
if gum confirm "Open it?"; then
  xdg-open "$out" >/dev/null 2>&1 &
fi
