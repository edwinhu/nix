# aerc, patched to tell its embedded terminal how big a pixel is.
#
# THE BUG. vaxis >= 0.16.0 sizes a child's sixel in CELLS. It derives the cell
# size from the CHILD pty's own pixel fields (widgets/term/action.go,
# sixelCellPixels): `cellWidth = vt.size.XPixel / vt.size.Cols`, falling back to
# 1 when the pixel field is zero. aerc has never populated them -- app/terminal.go
# handed vterm.Update a `vaxis.Resize{Cols, Rows}` and nothing else, and
# `grep -rn "XPixel|YPixel"` over aerc 0.22.0 returns no hits at all.
#
# So the cell is 1x1px, a 640x400 sixel is recorded as a 640-column by 400-row
# graphic, visibleGraphics() culls it on every frame, and positionSixel() emits
# rows-1 index scrolls that push the rendered page away with it. Inline images in
# HTML mail simply stop appearing, and the page layout is shredded by the scrolls.
#
# WHY IT ONLY BIT AT 0.22.0. aerc 0.21.0 pinned vaxis v0.15.0, which had no cell
# model for graphics at all -- it drew an image at its cursor origin whatever its
# size, so the same chawan output worked. The upgrade to 0.22.0 (vaxis v0.17.1)
# was taken for the sixel SCROLL fix and brought this with it.
#
# The host vaxis knows its own pixel geometry (`vx.Size()` carries XPixel and
# YPixel), so the patch derives a per-cell size from it and scales to the
# sub-window the embedded terminal occupies.
#
# `aerc = prev.aerc` explicitly at the call site: callPackage's auto-args resolve
# against the FINAL package set, so letting it fill `aerc` in would point this
# override at itself.
{ aerc }:

aerc.overrideAttrs (prev: {
  patches = (prev.patches or [ ]) ++ [ ./aerc-pty-pixels.patch ];

  # A build-time gate, because the patch is silent when it stops applying: aerc
  # would build, run, and render no images, which is exactly the failure it
  # exists to fix. Assert the field is actually populated in the source.
  postPatch = (prev.postPatch or "") + ''
    if ! grep -q 'resize.XPixel = w \* cellW' app/terminal.go; then
      echo "aerc: the pty pixel-geometry patch did not take -- app/terminal.go" >&2
      echo "does not set resize.XPixel. Without it vaxis sizes a child sixel at" >&2
      echo "1x1px per cell and culls every inline mail image." >&2
      exit 1
    fi
  '';

  passthru = (prev.passthru or { }) // { ptyPixelGeometry = true; };
})
