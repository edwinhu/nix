#!/usr/bin/env python3
"""Build Windows/Word-compatible Latin Modern fonts.

Word (at least in the word-render guest) will not render CFF-flavoured
OpenType: it lists the family in Application.FontNames but silently
substitutes Calibri on export.  It also matches families by name ID 1, which
Latin Modern sets per optical size ("LM Roman 10"), not by the typographic
family in name ID 16 ("Latin Modern Roman").

So: convert cubic CFF outlines to quadratic glyf outlines, and rewrite the
name table so the family is the typographic one.
"""
import os, sys
from fontTools.ttLib import TTFont, newTable
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen

MAX_ERR = 1.0

FACES = {
    "lmroman10-regular.otf":    ("Latin Modern Roman", "Regular"),
    "lmroman10-bold.otf":       ("Latin Modern Roman", "Bold"),
    "lmroman10-italic.otf":     ("Latin Modern Roman", "Italic"),
    "lmroman10-bolditalic.otf": ("Latin Modern Roman", "Bold Italic"),
    "lmmono10-regular.otf":     ("Latin Modern Mono",  "Regular"),
    "lmmono10-italic.otf":      ("Latin Modern Mono",  "Italic"),
    "latinmodern-math.otf":     ("Latin Modern Math",  "Regular"),
}

def otf_to_ttf(font, max_err=MAX_ERR):
    order = font.getGlyphOrder()
    glyphSet = font.getGlyphSet()
    glyf = newTable("glyf"); glyf.glyphOrder = order; glyf.glyphs = {}
    for name in order:
        pen = TTGlyphPen(glyphSet)
        glyphSet[name].draw(Cu2QuPen(pen, max_err, reverse_direction=True))
        glyf[name] = pen.glyph()
    font["glyf"] = glyf
    font["loca"] = newTable("loca")
    font["maxp"].numGlyphs = len(order)
    font["maxp"].tableVersion = 0x00010000
    for attr, val in (("maxZones",1),("maxTwilightPoints",0),("maxStorage",0),
                      ("maxFunctionDefs",0),("maxInstructionDefs",0),
                      ("maxStackElements",0),("maxSizeOfInstructions",0),
                      ("maxComponentElements",max((len(getattr(g,'components',[])) for g in glyf.glyphs.values()), default=0))):
        setattr(font["maxp"], attr, val)
    font["head"].indexToLocFormat = 0
    post = font["post"]
    post.formatType = 2.0
    post.extraNames = []
    post.mapping = {}
    post.glyphOrder = None
    for t in ("CFF ", "VORG"):
        if t in font: del font[t]
    font.sfntVersion = "\000\001\000\000"
    return font

def rename(font, family, sub):
    full = family if sub == "Regular" else f"{family} {sub}"
    n = font["name"]
    for pid, eid, lid in ((3,1,0x409),(1,0,0)):
        n.setName(family, 1, pid, eid, lid)
        n.setName(sub,    2, pid, eid, lid)
        n.setName(full,   4, pid, eid, lid)
        for nid in (16, 17):
            try: n.removeNames(nid, pid, eid, lid)
            except Exception: pass
    font["OS/2"].fsType = 0          # LM is GUST-licensed; embedding unrestricted
    return font

def main(srcdirs, outdir):
    os.makedirs(outdir, exist_ok=True)
    made = 0
    for fn, (fam, sub) in FACES.items():
        src = next((os.path.join(d, fn) for d in srcdirs
                    if os.path.exists(os.path.join(d, fn))), None)
        if not src:
            print(f"missing: {fn}", file=sys.stderr); continue
        f = TTFont(src)
        rename(otf_to_ttf(f), fam, sub)
        f.save(os.path.join(outdir, fn.replace(".otf", ".ttf")))
        made += 1
    print(f"built {made} fonts -> {outdir}")
    return 0 if made == len(FACES) else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:-1], sys.argv[-1]))
