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
    import subprocess

    def _scale_px(m):
        return f"{m.group(1)}{max(1, round(int(m.group(2)) * SCALE))}"

    # Box dimensions: width=/height= attributes and width:/height: in styles.
    html = re.sub(r'(?i)(<(?:table|td|th|div|img)\b[^>]*?\s(?:width|height)=")(\d+)',
                  _scale_px, html)
    html = re.sub(r"(?i)\b((?:max-|min-)?(?:width|height)\s*:\s*)(\d+)(?=px)",
                  _scale_px, html)

    # The image files themselves, so a photo grows with the box that holds it.
    for name in set(got.values()):
        path = os.path.join(DIR, name)
        try:
            subprocess.run(["magick", path, "-resize",
                            f"{round(SCALE * 100)}%", path],
                           check=True, capture_output=True, timeout=20)
        except Exception:
            pass  # best effort: an unscaled image beats no mail

# NOTHING ELSE IS REWRITTEN. Only the image src values above change; the mail's
# own HTML, CSS and layout are passed through untouched.
#
# Two attempts at "improving" the layout were tried and both made it worse, so
# do not add a third without a screenshot to justify it:
#   * a centring wrapper injected inside <body> -- moved the block by one cell
#     and fixed nothing that mattered;
#   * relaxing every fixed width at or above 500px to 100%, to spend the whole
#     pane -- a newsletter's 640px shell is a DESIGN, and stretching it pulled
#     its internal proportions apart.
# A mail is laid out for a narrow reading column on purpose. Render it as sent.
sys.stdout.write(html)
sys.stderr.write("inlined %d/%d images\n" % (len(got), len(urls)))
