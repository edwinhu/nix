"""Extract HTML from RFC822 stdin, inline cid attachments, and emit UTF-8.

Remote image URLs are left untouched; fetching them is the renderer's policy.
Usage: mail-inline-images.py < message.eml > index.html (no arguments).
"""
import base64, email, email.policy, html as _html
import re, sys

# extract_html's existing attachment cap; no remote downloads or CLI budget.
MAX = 40
if len(sys.argv) != 1:
    sys.exit("usage: mail-inline-images.py < message.eml > index.html")
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
