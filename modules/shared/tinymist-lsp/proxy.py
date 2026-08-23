"""Run `tinymist lsp` with a project root it would not otherwise find.

tinymist takes its root from LSP `initializationOptions.rootPath`. It has no
`--root` flag (checked: neither `tinymist --help` nor `tinymist lsp --help`
offers one), it ignores `TYPST_ROOT` (a typst-CLI variable), and it is
unaffected by cwd -- `tinymist lint` returns the same error run from the repo
root as from a subdirectory. Absent a root it synthesises a package per FILE
("@ws/p0:0.0.0"), rooted at that file's own directory, so any
`../../templates/theme.typ` import fails as "would escape the package root" and
the file is never indexed: no diagnostics, no hover.

Claude Code's `lspServers` config accepts only command/args/extensionToLanguage,
with no way to pass initializationOptions. So this sits in the middle of the
stdio pipe, rewrites the one `initialize` request, and then gets out of the way
by splicing the streams raw.

Root is the nearest ancestor of $PWD holding a marker (see MARKERS). Override
with TINYMIST_PROJECT_ROOT.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

MARKERS = ("templates/theme.typ", "typst.toml", "pixi.toml", ".git")


# Directory fragments that mark a project-local environment. A tinymist inside
# one is pinned to that project's lockfile, so the LSP's behaviour would change
# with cwd -- and the version can drift from the system install.
def find_root(start: Path) -> Path | None:
    for d in (start, *start.parents):
        if any((d / m).exists() for m in MARKERS):
            return d
    return None


def read_message(stream) -> tuple[bytes, bytes] | None:
    """Return (raw_headers, body) or None at EOF."""
    header = b""
    while not header.endswith(b"\r\n\r\n"):
        ch = stream.read(1)
        if not ch:
            return None
        header += ch
    length = 0
    for line in header.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    return header, stream.read(length)


def frame(body: bytes) -> bytes:
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


def main() -> int:
    # Nix pins this to a store path; the wrapper always sets it.
    exe = os.environ.get("TINYMIST_BIN") or shutil.which("tinymist")
    if exe is None:
        print("tinymist-lsp: tinymist not found", file=sys.stderr)
        return 127

    root = os.environ.get("TINYMIST_PROJECT_ROOT") or find_root(Path.cwd())
    child = subprocess.Popen(
        [exe, "lsp", *sys.argv[1:]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    c_in, c_out = child.stdin, child.stdout
    assert c_in is not None and c_out is not None

    # child -> client, verbatim, for the whole session.
    #
    # NOT shutil.copyfileobj: it never flushes, so responses sit in
    # sys.stdout.buffer and the client blocks forever waiting for a reply that
    # was already written. Every read must be flushed straight through.
    def pump() -> None:
        out = sys.stdout.buffer
        while True:
            chunk = c_out.read1(65536)
            if not chunk:
                break
            out.write(chunk)
            out.flush()

    threading.Thread(target=pump, daemon=True).start()

    stdin = sys.stdin.buffer
    injected = root is None          # nothing to do if we could not find a root
    while True:
        msg = read_message(stdin)
        if msg is None:
            break
        _, body = msg
        if not injected:
            try:
                obj = json.loads(body)
            except ValueError:
                obj = None
            if isinstance(obj, dict) and obj.get("method") == "initialize":
                params = obj.setdefault("params", {})
                opts = params.get("initializationOptions") or {}
                # rootPath is what tinymist reads; typstExtraArgs covers the
                # compile side, which resolves imports independently.
                opts.setdefault("rootPath", str(root))
                opts.setdefault("typstExtraArgs", ["--root", str(root)])
                params["initializationOptions"] = opts
                body = json.dumps(obj).encode()
                injected = True
                print(f"tinymist-root-proxy: rootPath={root}", file=sys.stderr)
        c_in.write(frame(body))
        c_in.flush()

    try:
        c_in.close()
    except OSError:
        pass
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
