"""Fetch a mail's remote images and rewrite them to same-origin paths.

chawan will not load an https image into an http document (measured: sixel
emitted for a same-origin http image, none for an https one on the same page),
and the local server that makes the document "remote enough" to load images at
all can only speak http. So the images are pulled here and rewritten to
relative names the same server serves.

Fetching is bounded and best-effort: a mail with a dead or slow CDN must still
render its text rather than hang the message view.
"""
import base64, concurrent.futures as cf, email, email.policy, hashlib, html as _html
import os, re, sys, urllib.request

DIR, TIMEOUT, MAX = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
# Zoom factor. 1.0 renders the mail at its authored size.
SCALE = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
# BYTES, NOT TEXT. sys.stdin.read() decodes against the locale, so a part
# declaring windows-1252 or latin-1 -- where the smart quotes are the single
# bytes 92, 93, 94 and 97 -- died with UnicodeDecodeError. The caller's
# `|| printf '%s' "$PART"` then wrote those raw bytes out undeclared and
# chawan rendered mojibake, which is why curly quotes in particular came out
# wrong. The mail declares its own charset; honour that rather than the locale.
raw = sys.stdin.buffer.read()


def decode_loose(data):
    """Bytes to text for input that is NOT a message, so nothing declares a
    charset. cp1252 is the fallback because it is what mail that lies about
    being latin-1 actually is, and it decodes every byte, so this cannot
    raise."""
    for enc in ("utf-8", "cp1252"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


# STDIN IS THE WHOLE MESSAGE, NOT THE HTML PART.
#
# The `o` keybind pipes with `:pipe -m`, so what arrives is full RFC822 --
# headers, MIME boundaries and base64 blobs. Everything below this point works
# on markup, so handing it the raw message rendered the SOURCE: `index.html`
# came out byte-identical to the .eml, opening with `Delivered-To:`. Extract
# the part first.
#
# Only `-m` can resolve cid: images: a text/html part alone has no access to
# the related attachments its own <img> tags point at.
def extract_html(data):
    # Not a message: an earlier caller's already-extracted part. Pass it on.
    head = decode_loose(data[:200]).strip() or "x"
    if not re.match(r"(?i)^[!-9;-~]+:", head):
        return decode_loose(data)
    # from_bytes, not from_string: the parser reads each part's declared
    # charset and decodes it correctly, which is the whole point of getting
    # here with bytes still intact.
    msg = email.message_from_bytes(data, policy=email.policy.default)
    if not msg.get("Content-Type") and not msg.get("MIME-Version"):
        return decode_loose(data)

    body = msg.get_body(preferencelist=("html", "plain"))
    if body is None:
        return decode_loose(data)
    try:
        content = body.get_content()
    except Exception:
        return decode_loose(data)

    if body.get_content_type() == "text/plain":
        # No HTML alternative. Wrap it so the browser renders text as text
        # rather than collapsing every newline.
        content = (
            "<meta charset=\"utf-8\"><pre style=\"white-space:pre-wrap;"
            "font:14px/1.5 ui-monospace,monospace\">"
            + _html.escape(content)
            + "</pre>"
        )

    # cid: images live as sibling parts and no server can serve them by name,
    # so they become data: URIs here. Bounded by the same MAX as remote images.
    cids = {}
    for part in msg.walk():
        cid = (part.get("Content-ID") or "").strip().strip("<>")
        if not cid or part.get_content_maintype() != "image":
            continue
        if len(cids) >= MAX:
            break
        try:
            payload = part.get_payload(decode=True)
        except Exception:
            continue
        if not payload:
            continue
        ctype = part.get_content_type()
        cids[cid] = "data:%s;base64,%s" % (
            ctype, base64.b64encode(payload).decode("ascii"))
    for cid, uri in cids.items():
        content = content.replace("cid:" + cid, uri)
    return content


html = extract_html(raw)

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

# SAY WHAT WE ACTUALLY WROTE. The text above is decoded, and it goes out as
# UTF-8 below whatever the locale is -- but a part that declared windows-1252
# still CARRIES that declaration, and chawan believes the document over the
# bytes. Left alone, correctly decoded curly quotes get re-mojibaked at render.
# Drop any charset the mail declared and state ours once, first.
html = re.sub(
    r"(?is)<meta[^>]*?charset[^>]*?>", "", html)
html = re.sub(
    r"(?is)(<head\b[^>]*>)", r'\1<meta charset="utf-8">', html, count=1)
if "<meta charset=" not in html:
    html = '<meta charset="utf-8">' + html

# Bytes, for the same reason stdin was read as bytes: sys.stdout encodes
# against the locale, and aerc does not guarantee a UTF-8 one.
sys.stdout.buffer.write(html.encode("utf-8", "replace"))
sys.stderr.write("inlined %d/%d images\n" % (len(got), len(urls)))
