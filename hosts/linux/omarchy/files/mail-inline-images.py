"""Fetch a mail's remote images and rewrite them to same-origin paths.

chawan will not load an https image into an http document (measured: sixel
emitted for a same-origin http image, none for an https one on the same page),
and the local server that makes the document "remote enough" to load images at
all can only speak http. So the images are pulled here and rewritten to
relative names the same server serves.

Fetching is bounded and best-effort: a mail with a dead or slow CDN must still
render its text rather than hang the message view.
"""
import concurrent.futures as cf, hashlib, os, re, sys, urllib.request

DIR, TIMEOUT, MAX = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
html = sys.stdin.read()

urls, seen = [], set()
for m in re.finditer(r'(?i)<img\b[^>]*?\bsrc\s*=\s*["\']([^"\']+)["\']', html):
    u = m.group(1).strip()
    if u.lower().startswith(("http://", "https://")) and u not in seen:
        seen.add(u); urls.append(u)
urls = urls[:MAX]

# The extension is load-bearing: the local server types files by suffix, and a
# bare hash is served as application/octet-stream, which chawan will not draw.
EXT = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
       "image/webp": ".webp", "image/svg+xml": ".svg", "image/bmp": ".bmp",
       "image/x-icon": ".ico", "image/vnd.microsoft.icon": ".ico"}

def grab(u):
    stem = hashlib.sha256(u.encode()).hexdigest()[:16]
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            ctype = (r.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            data = r.read(4_000_000)
        if not data:
            return None
        name = stem + EXT.get(ctype, os.path.splitext(u.split("?")[0])[1][:5] or ".png")
        open(os.path.join(DIR, name), "wb").write(data)
        return u, name
    except Exception:
        return None

got = {}
if urls:
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        for r in ex.map(grab, urls):
            if r: got[r[0]] = r[1]

for u, name in got.items():
    html = html.replace(u, name)

# Centering. A newsletter is a fixed ~640px design and chawan centers it in
# whole COLUMNS, so the leftover width does not split evenly and the block sits
# a couple of cells right of centre. A sheet targeting body>* missed (the
# content is not a direct child of body) and wrapping the whole string put the
# div before the DOCTYPE, where the parser drops it. Inject INSIDE body, which
# does not depend on the mail's structure.
m = re.search(r"(?i)<body\b[^>]*>", html)
if m:
    # Centre the mail: chawan centres a block in whole COLUMNS, so a fixed
    # ~640px newsletter does not split the leftover pane width evenly. This
    # wrapper took it from 744/687 to 728/688 -- about one cell off, which is
    # the floor for a cell-quantised renderer.
    #
    # A hero image still sits one cell (16px) right of the masthead rules and
    # the photos below. That is the mail's own structure -- a spacer cell --
    # rendered faithfully and rounded up to a whole column, NOT something the
    # served document can override. Four rules were measured against it and
    # every one left the number at exactly 744 vs 728: zeroing the image
    # margin/padding, zeroing table margins, making images display:block, and
    # a body>* stylesheet. Do not spend another pass on it without first
    # confirming chawan can move that image at all.
    pass

# WIDEN THE WRAPPER. A newsletter is built as one fixed-width table -- this one
# is `<table id="template_container" style="width:640px">` -- because that is
# what a mail client's narrow reading column wants. chawan honours it exactly,
# so in a 126-column pane the mail renders as a 40-column ribbon with two
# thirds of the pane blank.
#
# Only WIDE boxes are relaxed: at 500px and up a width is the outer shell, and
# below it the number is doing real layout work (this mail's 225px thumbnail
# columns, spacer cells at width="1"). Rewriting those too would collapse the
# two-column story rows into a stack.
WIDE_PX = 500

def _relax_attr(m):
    tag, name, num = m.group(1), m.group(2), int(m.group(3))
    return f'{tag}{name}="100%"' if num >= WIDE_PX else m.group(0)

html = re.sub(
    r'(?i)(<(?:table|td|div)\b[^>]*?)(\swidth=)"(\d+)"',
    _relax_attr,
    html,
)

def _relax_style(m):
    num = int(m.group(2))
    return f"{m.group(1)}100%" if num >= WIDE_PX else m.group(0)

html = re.sub(r"(?i)(\bwidth\s*:\s*)(\d+)px", _relax_style, html)
sys.stdout.write(html)
sys.stderr.write("inlined %d/%d images\n" % (len(got), len(urls)))
