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
# Zoom factor. 1.0 renders the mail at its authored size.
SCALE = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
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

# ZOOM THE WHOLE MAIL, BOTH HALVES OR NEITHER.
#
# A newsletter is a fixed ~640px design. chawan renders that faithfully, so in a
# ~180-column pane it is a 40-column ribbon with the rest of the desktop blank.
#
# Widening the BOXES alone was tried and looked worse: chawan emits an image at
# its natural pixel size whatever cell ratio it is given (measured -- a 300px
# image stayed 300x120 at pixels-per-column 16, 8 and 5), so the layout stretched
# while every photo stayed put and the proportions came apart. Scaling the image
# FILES by the same factor is what keeps the design intact while making it fill
# the pane.
if SCALE > 1.01:
    # WIDEN THE BOXES ONLY. The image FILES are deliberately untouched: an
    # earlier version re-encoded each one through `magick` at the same factor,
    # and that is what made every image vanish (measured: 0 placements on both
    # aerc 0.21.0 and 0.22.0). Layout width and image rendering are independent;
    # coupling them was the mistake.
    def _scale_px(m):
        return f"{m.group(1)}{max(1, round(int(m.group(2)) * SCALE))}"

    html = re.sub(r'(?i)(<(?:table|td|th|div)\b[^>]*?\s(?:width)=")(\d+)', _scale_px, html)
    html = re.sub(r"(?i)\b((?:max-|min-)?width\s*:\s*)(\d+)(?=px)", _scale_px, html)

sys.stdout.write(html)
sys.stderr.write("inlined %d/%d images\n" % (len(got), len(urls)))
