#!/usr/bin/env python3
"""Render a mail's HTML the way the recipient will see it, inline in the terminal.

    mail-preview FILE.eml            # or an MML template
    mail-preview -a work 1234        # an existing message/draft, -m defaults to drafts
    mail-preview --html < body.html  # bare HTML fragment on stdin

This is a REAL render -- headless Chromium screenshots the HTML, chafa paints
the PNG into the terminal -- not a text dump. That is the whole point: chawan
and w3m tell you the words survived, and say nothing about whether the styling
did. Reviewing agent-written mail needs the second thing.

The PNG is kept and its path printed, so a preview that is too small to judge
can be opened at full size without recomposing anything.
"""

import argparse
import base64
import email
import email.policy
import os
import quopri
import re
import shutil
import subprocess
import sys
import tempfile
import time

CHROMIUM = next(
    (b for b in ("chromium", "chromium-browser", "google-chrome-stable", "chrome")
     if shutil.which(b)), None,
)
WIDTH = 900  # a desktop mail reading pane; narrower than a browser window
TALL = 6000  # render window height: a ceiling on message length, then cropped

# Neutral chrome around the message so the render shows the recipient's frame
# (white page, system font, header block) rather than the raw fragment floating
# on transparency -- which is what makes a broken background or a stray margin
# visible at all.
PAGE = """<!doctype html><meta charset="utf-8"><style>
  html {{ background: #e5e5e5; }}
  body {{ margin: 0; padding: 24px;
         font: 15px/1.5 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
         color: #1a1a1a; }}
  .hdr {{ max-width: {w}px; margin: 0 auto 14px; background: #fff;
         border: 1px solid #d0d0d0; border-radius: 6px 6px 0 0;
         padding: 12px 20px; font-size: 13px; color: #555; }}
  .hdr b {{ color: #222; font-weight: 600; }}
  .hdr .subj {{ font-size: 17px; color: #111; font-weight: 600; margin-bottom: 6px; }}
  .msg {{ max-width: {w}px; margin: 0 auto; background: #fff;
         border: 1px solid #d0d0d0; border-top: 0; padding: 20px; }}
  .msg img {{ max-width: 100%; }}
</style>
<div class="hdr">{headers}</div>
<div class="msg">{body}</div>
"""


def from_mml(text):
    """Pull headers + the text/html part out of an MML template."""
    head, _, body = text.partition("\n\n")
    parts = re.findall(r"<#part type=text/html>\n(.*?)(?:<#/part>|\Z)", body, re.S)
    return head, "\n".join(parts) if parts else body


def from_eml(raw):
    msg = email.message_from_string(raw, policy=email.policy.default)
    html = msg.get_body(preferencelist=("html",))
    if html is not None:
        body = html.get_content()
    else:
        plain = msg.get_body(preferencelist=("plain",))
        body = ("<pre style='white-space:pre-wrap;font:inherit'>"
                + (plain.get_content() if plain else "") + "</pre>")
    head = "\n".join(f"{k}: {v}" for k, v in msg.items())
    return head, body


def decode_mml_encodings(text):
    """MML templates are 7-bit clean, but a fetched draft can come back
    quoted-printable inside the MML wrapper (himalaya does not always decode)."""
    if re.search(r"=[0-9A-F]{2}", text) and "=\n" in text:
        try:
            return quopri.decodestring(text.encode()).decode("utf-8", "replace")
        except ValueError:
            pass
    return text


def header_html(head):
    keep = ("from", "to", "cc", "bcc", "subject")
    rows, subject = [], ""
    for line in head.split("\n"):
        name, _, value = line.partition(":")
        if name.strip().lower() in keep and value.strip():
            if name.strip().lower() == "subject":
                subject = escape(value.strip())
            else:
                rows.append(f"<div><b>{escape(name.strip())}:</b> {escape(value.strip())}</div>")
    return (f'<div class="subj">{subject}</div>' if subject else "") + "".join(rows)


def escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render(head, body, out_png):
    if CHROMIUM is None:
        sys.exit("mail-preview: no chromium on PATH — cannot render")
    page = PAGE.format(w=WIDTH, headers=header_html(head), body=body)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as fh:
        fh.write(page)
        html_path = fh.name
    # A throwaway profile, or chromium attaches to the running browser's
    # profile (the CDP one on :9222) and the screenshot never happens.
    profile = tempfile.mkdtemp(prefix="mail-preview-profile.")
    try:
        # Chromium's --screenshot captures EXACTLY the window, not the page: an
        # 800px window over a 300px message yields 500px of empty gray, and over
        # a 2000px message it silently cuts the message in half. Neither
        # --headless=old nor =new full-pages it. So render into a deliberately
        # over-tall window and crop back to the content afterwards.
        #
        # WAIT ON THE FILE, NOT ON THE PROCESS. Headless chromium writes the PNG
        # and then does NOT exit here -- `subprocess.run` with any timeout blocks
        # for the whole timeout even though the render finished in a second. So
        # poll for the file to appear and stop growing, then kill it.
        proc = subprocess.Popen(
            [CHROMIUM, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--no-sandbox", "--no-first-run", "--no-default-browser-check",
             "--disable-extensions", f"--user-data-dir={profile}",
             "--virtual-time-budget=3000",
             f"--window-size={WIDTH + 48},{TALL}",
             f"--screenshot={out_png}", f"file://{html_path}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        size = -1
        for _ in range(150):  # 30s ceiling
            time.sleep(0.2)
            if os.path.exists(out_png):
                now = os.path.getsize(out_png)
                if now > 0 and now == size:
                    break
                size = now
            if proc.poll() is not None:
                break
        proc.kill()
        proc.wait(timeout=5)
    finally:
        os.unlink(html_path)
        shutil.rmtree(profile, ignore_errors=True)
    if not os.path.exists(out_png) or os.path.getsize(out_png) == 0:
        sys.exit("mail-preview: chromium produced no screenshot")
    crop_to_content(out_png)


def crop_to_content(png):
    """Trim the dead gray below the message left by the over-tall window.

    Only the BOTTOM is trimmed: a full -trim would also eat the side margins,
    and the gray gutter is what makes the message read as a card in a client
    rather than as a bare fragment. If ImageMagick is missing the preview is
    still correct, just padded, so this never fails the render.
    """
    if not shutil.which("magick"):
        return
    try:
        geom = subprocess.run(
            ["magick", png, "-background", "#e5e5e5", "-fuzz", "1%",
             "-format", "%@", "info:"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout.strip()
        m = re.match(r"(\d+)x(\d+)\+(\d+)\+(\d+)", geom)
        if not m:
            return
        _cw, ch, _cx, cy = (int(g) for g in m.groups())
        width = int(subprocess.run(["magick", png, "-format", "%w", "info:"],
                                   capture_output=True, text=True,
                                   timeout=30, check=True).stdout.strip())
        height = min(TALL, cy + ch + 24)  # 24 = the page's own bottom padding
        subprocess.run(["magick", png, "-crop", f"{width}x{height}+0+0",
                        "+repage", png], capture_output=True, timeout=30, check=True)
    except (subprocess.SubprocessError, ValueError):
        pass


def show_chawan(head, body):
    """Text render, for use INSIDE aerc (`:pipe -m`).

    aerc's own text/html filter is chawan, so this is the same renderer the
    message view uses -- colors, bold, links and table layout survive; images
    and fonts do not. It exists because no pixel render works in an aerc
    terminal tab: chafa -f kitty hangs on a /dev/tty probe aerc never answers,
    and -f sixel draws nothing on this Ghostty build.
    """
    cha = os.environ.get("CHA_HTML")
    cmd = [cha] if cha else ["cha", "-d", "-T", "text/html", "-I", "UTF-8", "-O", "UTF-8"]
    if not cha and not shutil.which("cha"):
        sys.exit("mail-preview: no chawan (cha) on PATH")
    for line in head.split("\n"):
        name, _, value = line.partition(":")
        if name.strip().lower() in ("from", "to", "cc", "bcc", "subject") and value.strip():
            print(f"{name.strip()}: {value.strip()}")
    print()
    sys.stdout.flush()
    subprocess.run(cmd, input=body, text=True, check=False)


def show_external(png):
    """Open the PNG in its own window.

    This is the ONLY preview that works from inside aerc: aerc's embedded
    terminal parses and DISCARDS kitty graphics escapes, so chafa output piped
    into an aerc terminal tab is silently blank (same constraint the PDF filter
    works around via herdr's pane-graphics).
    """
    viewer = next((b for b in ("imv", "hylo", "xdg-open") if shutil.which(b)), None)
    if viewer is None:
        print(f"rendered: {png}")
        return
    subprocess.Popen([viewer, png], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def show(png):
    if shutil.which("chafa"):
        # chafa picks kitty/sixel/symbols by probing the terminal; --scale max
        # fills the width without overflowing it. Height is left free so a long
        # message scrolls in the pager rather than being squashed to one screen.
        subprocess.run(["chafa", "--scale", "max", png], check=False)
    else:
        print(f"(no chafa) rendered: {png}")


def fetch(account, mailbox, msgid):
    """The raw RFC 5322 bytes of one message, straight off himalaya's stdout.

    `message read --raw` is the v2 replacement for v1's `message export -F -d
    <dir>`: it dumps to stdout, so there is no temp dir to manage and no file to
    wait for. `read` without --raw would render himalaya's own header+text view,
    which is not parseable as MIME.
    """
    r = subprocess.run(
        ["himalaya", "message", "read", "--raw", "-a", account,
         "-m", mailbox, msgid],
        capture_output=True, text=True, errors="replace", timeout=120,
    )
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit(f"mail-preview: could not read {msgid} from {mailbox}: "
                 f"{r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", nargs="?", help="file path, or message id with -a")
    ap.add_argument("-a", "--account")
    ap.add_argument("-m", "--mailbox", default="drafts")
    ap.add_argument("--html", action="store_true", help="stdin is a bare HTML fragment")
    ap.add_argument("-o", "--out", help="where to write the PNG")
    ap.add_argument("--open", action="store_true",
                    help="open in an image viewer instead of painting in the terminal")
    ap.add_argument("--text", action="store_true",
                    help="render through chawan instead (works inside aerc)")
    args = ap.parse_args()

    if args.html or args.target in (None, "-"):
        head, body = "", sys.stdin.read()
        if not args.html:
            head, body = from_mml(body) if "<#part" in body else from_eml(body)
    elif args.account and not os.path.exists(args.target):
        head, body = from_eml(fetch(args.account, args.mailbox, args.target))
    else:
        with open(args.target, errors="replace") as fh:
            raw = fh.read()
        head, body = from_mml(raw) if "<#part" in raw else from_eml(raw)

    body = decode_mml_encodings(body)
    if args.text:
        show_chawan(head, body)
        return
    png = args.out or tempfile.mkstemp(prefix="mail-preview.", suffix=".png")[1]
    render(head, body, png)
    if args.open or not sys.stdout.isatty():
        show_external(png)
    else:
        show(png)
    print(f"\nrendered: {png}", file=sys.stderr)


if __name__ == "__main__":
    main()
