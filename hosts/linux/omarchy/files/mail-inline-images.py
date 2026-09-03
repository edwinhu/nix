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
sys.stdout.write(html)
sys.stderr.write("inlined %d/%d images\n" % (len(got), len(urls)))
