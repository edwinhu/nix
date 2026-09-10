#!/usr/bin/env python3
"""Make chawan's mail dump readable on a terminal whose ground the mail never saw.

A mail is authored against a page whose background it controls. Where it states
that background, its own text colour is correct by construction and is left
exactly alone -- black on white renders as black on white.

The failure is the other case. Plenty of elements state a text colour and NO
background: the Docket sets #929292 on its kickers and paints no ground under
them. In a browser those inherit the page's white. In a terminal they inherit
whatever the terminal is, and on a dark theme mid-grey on near-black is the
"why is the font grey" report.

So the rule is exactly: IF NO BACKGROUND IS SET, DROP THE TEXT COLOUR. The run
falls back to the terminal's default foreground, which is by definition legible
against the terminal's default background. Nothing is recoloured to a palette
of ours, no canvas is forced, and a mail that ships its own dark design keeps
it -- it states a background, so it is never touched.

No luminance test. A first version dropped only foregrounds it judged "dark",
and #929292 -- the exact colour in the report -- scored 0.57 and was left
alone, so the filter was a no-op on the case it existed for. Whether a mid
grey reads against an unknown terminal theme is not a judgement this can make
correctly; whether a background was stated is a fact in the stream. Use the
fact.
"""

import re
import sys

SGR = re.compile(rb"\x1b\[([0-9;]*)m")


class State:
    __slots__ = ("bg_set", "fg_set")

    def __init__(self):
        self.fg_set = False    # has the mail stated a foreground?
        self.bg_set = False    # has a background been stated?

    def apply(self, codes):
        """Update state from one SGR parameter list, and return it possibly rewritten."""
        out = []
        i = 0
        while i < len(codes):
            c = codes[i]
            if c in ("", "0"):
                self.fg_set = False
                self.bg_set = False
                out.append(c)
            elif c == "39":
                self.fg_set = False
                out.append(c)
            elif c == "49":
                self.bg_set = False
                out.append(c)
            elif c == "38" and i + 1 < len(codes) and codes[i + 1] == "2":
                self.fg_set = True
                out.extend(codes[i:i + 5])
                i += 4
            elif c == "48" and i + 1 < len(codes) and codes[i + 1] == "2":
                self.bg_set = True
                out.extend(codes[i:i + 5])
                i += 4
            elif c == "38" and i + 1 < len(codes) and codes[i + 1] == "5":
                self.fg_set = True
                out.extend(codes[i:i + 3])
                i += 2
            elif c == "48" and i + 1 < len(codes) and codes[i + 1] == "5":
                self.bg_set = True
                out.extend(codes[i:i + 3])
                i += 2
            elif c.isdigit() and (30 <= int(c) <= 37 or 90 <= int(c) <= 97):
                self.fg_set = True
                out.append(c)
            elif c.isdigit() and (40 <= int(c) <= 47 or 100 <= int(c) <= 107):
                self.bg_set = True
                out.append(c)
            else:
                out.append(c)
            i += 1
        return out


def main():
    data = sys.stdin.buffer.read()
    out = bytearray()
    st = State()
    pos = 0
    # `39` is emitted before any run the mail coloured but never grounded;
    # the tracked state decides, so a run is only ever corrected once.
    for m in SGR.finditer(data):
        seg = data[pos:m.start()]
        if seg:
            if seg.strip() and st.fg_set and not st.bg_set:
                out += b"\x1b[39m"
                st.fg_set = False
            out += seg
        codes = m.group(1).decode("ascii", "replace").split(";")
        out += b"\x1b[" + ";".join(st.apply(codes)).encode() + b"m"
        pos = m.end()
    seg = data[pos:]
    if seg:
        if seg.strip() and st.fg_set and not st.bg_set:
            out += b"\x1b[39m"
        out += seg
    sys.stdout.buffer.write(bytes(out))


if __name__ == "__main__":
    main()
