#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf>=1.23.0", "requests>=2.31.0", "bibtexparser>=1.4.0"]
# ///
"""
Paperpile -> Readwise incremental highlight sync (Linux, pull-based).

Design (see README):
  1. Ask rclone for PDFs in the Paperpile Drive folder modified since the last
     successful run (Paperpile bumps a PDF's Drive modifiedTime when you save
     annotations), and copy ONLY those to a temp dir. No full-library download,
     no watchdog, no browser.
  2. Extract markup annotations (highlight/underline/strikeout/squiggly + sticky
     notes) with PyMuPDF, reading the highlighted text via clip-rect.
  3. Resolve title/author from paperpile.bib (fallback: parse the filename).
  4. POST to Readwise; let Readwise dedupe by (title, author, text). Re-processing
     an unchanged-but-touched file is therefore harmless.
  5. Persist the run time only on success so the next run's window starts there.

Token: READWISE_TOKEN, else READWISE_TOKEN_FILE (both already in this box's env
via agenix). Reuses the pure functions from the original Drive daemon.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import shutil
import logging
from datetime import datetime, timezone
from pathlib import Path

import fitz  # PyMuPDF
import bibtexparser
import requests

# Silence benign "cannot create appearance stream for widgets" noise on form PDFs.
try:
    fitz.TOOLS.mupdf_display_errors(False)
except Exception:
    pass

READWISE_API_URL = "https://readwise.io/api/v2/highlights/"
DEFAULT_REMOTE = os.environ.get("PAPERPILE_RCLONE_REMOTE", "google-drive:resources/Paperpile")
WATCH_SUBDIR = os.environ.get("PAPERPILE_WATCH_SUBDIR", "All Papers")
BIB_NAME = os.environ.get("PAPERPILE_BIB", "paperpile.bib")
STATE_FILE = Path(os.environ.get("PAPERPILE_STATE",
                  str(Path.home() / ".local/state/paperpile-readwise/last_sync")))
DEFAULT_FIRST_WINDOW = os.environ.get("PAPERPILE_FIRST_WINDOW", "30d")

logger = logging.getLogger("paperpile-readwise")


# ---------------------------------------------------------------------------
# Readwise token (reused from the original daemon)
# ---------------------------------------------------------------------------
def get_readwise_token() -> str | None:
    token = os.environ.get("READWISE_TOKEN")
    if token:
        return token.strip()
    token_file = os.environ.get("READWISE_TOKEN_FILE")
    if token_file and Path(token_file).exists():
        return Path(token_file).read_text().strip()
    return None


# ---------------------------------------------------------------------------
# Annotation extraction (reused from the original daemon)
# ---------------------------------------------------------------------------
def extract_annotations(pdf_path: str) -> list[dict]:
    path = Path(pdf_path)
    if not path.exists():
        raise FileNotFoundError(f"PDF file not found: {pdf_path}")
    annotations: list[dict] = []
    doc = fitz.open(pdf_path)
    try:
        for page_num, page in enumerate(doc):
            for annot in page.annots() or []:
                annot_type = annot.type[1].lower()  # "Highlight" -> "highlight"
                if annot_type not in ("highlight", "underline", "strikeout", "squiggly"):
                    if annot_type not in ("text", "freetext"):
                        continue  # skip links, shapes, popups, etc.
                text = ""
                rect = annot.rect
                try:
                    text = page.get_text("text", clip=rect).strip()
                except Exception:
                    pass
                annotations.append({
                    "type": annot_type,
                    "page": page_num,
                    "text": text,
                    "content": annot.info.get("content", ""),
                    "rect": [rect.x0, rect.y0, rect.x1, rect.y1] if rect else None,
                    "created": annot.info.get("creationDate", "") or annot.info.get("modDate", ""),
                })
    finally:
        doc.close()
    return annotations


# ---------------------------------------------------------------------------
# BibTeX metadata (reused from the original daemon)
# ---------------------------------------------------------------------------
def load_bibtex(bib_path: str) -> dict:
    path = Path(bib_path)
    if not path.exists():
        return {}
    with open(bib_path, encoding="utf-8") as f:
        bib_database = bibtexparser.load(f)
    lookup: dict[str, dict] = {}
    for entry in bib_database.entries:
        file_field = entry.get("file", "")
        if not file_field:
            continue
        for filepath in file_field.split(";"):
            filepath = filepath.strip()
            if filepath:
                lookup[filepath] = {
                    "title": entry.get("title", "").strip("{}"),
                    "author": entry.get("author", ""),
                    "date": entry.get("date", entry.get("year", "")),
                    "journal": entry.get("journaltitle", entry.get("journal", "")),
                }
    return lookup


def get_metadata(pdf_path: str, bibtex_db: dict) -> dict:
    normalized = pdf_path.replace("\\", "/")
    if normalized in bibtex_db:
        return bibtex_db[normalized]
    filename = Path(normalized).name
    for key, value in bibtex_db.items():
        if Path(key).name == filename:
            return value
    stem = Path(normalized).stem
    m = re.match(r"^(.+?)\s+(\d{4})\s*-\s*(.+)$", stem)
    if m:
        return {"title": m.group(3).strip(), "author": m.group(1).strip(),
                "date": m.group(2), "journal": ""}
    return {"title": stem, "author": "Unknown", "date": "", "journal": ""}


# ---------------------------------------------------------------------------
# Readwise payload + send (reused, with a stable source_url for grouping)
# ---------------------------------------------------------------------------
def build_readwise_payload(highlights: list[dict], metadata: dict) -> dict:
    readwise_highlights = []
    for hl in highlights:
        text = hl.get("text", "") or hl.get("content", "")  # sticky notes have no clip text
        if not text:
            continue
        highlighted_at = None
        created = hl.get("created", "")
        if created:
            try:
                if created.startswith("D:"):
                    created = created[2:]
                dt = datetime.strptime(created[:14], "%Y%m%d%H%M%S")
                highlighted_at = dt.isoformat() + "Z"
            except (ValueError, IndexError):
                pass
        rw = {
            "text": text,
            "title": metadata.get("title", "Unknown"),
            "author": metadata.get("author", ""),
            "source_type": "paperpile",
            "category": "articles",
            "location_type": "page",
            "location": hl.get("page", 0) + 1,
        }
        note = hl.get("content", "")
        if note and note != text:
            rw["note"] = note
        if highlighted_at:
            rw["highlighted_at"] = highlighted_at
        readwise_highlights.append(rw)
    return {"highlights": readwise_highlights}


def sync_to_readwise(payload: dict, token: str) -> dict:
    if not payload["highlights"]:
        return {"success": True, "count": 0}
    headers = {"Authorization": f"Token {token}", "Content-Type": "application/json"}
    try:
        r = requests.post(READWISE_API_URL, json=payload, headers=headers, timeout=30)
    except requests.RequestException as e:
        return {"success": False, "error": str(e)}
    if r.ok:
        return {"success": True, "count": len(payload["highlights"])}
    if r.status_code == 401:
        return {"success": False, "error": "401 auth failed — check Readwise token"}
    return {"success": False, "error": f"{r.status_code}: {r.text[:200]}"}


# ---------------------------------------------------------------------------
# rclone driver
# ---------------------------------------------------------------------------
def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    logger.debug("exec: %s", " ".join(cmd))
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def read_state() -> datetime | None:
    try:
        ts = STATE_FILE.read_text().strip()
        return datetime.fromtimestamp(float(ts), tz=timezone.utc)
    except (FileNotFoundError, ValueError):
        return None


def write_state(when: datetime) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(str(when.timestamp()))


def compute_max_age(args) -> str:
    """rclone --max-age string. Explicit override wins; else since-last-run + buffer; else first-run default."""
    if args.max_age:
        return args.max_age
    last = read_state()
    if last is None:
        return DEFAULT_FIRST_WINDOW
    # seconds since last run + 1h buffer to catch clock skew / in-flight saves
    secs = int((datetime.now(timezone.utc) - last).total_seconds()) + 3600
    return f"{max(secs, 3600)}s"


def rclone_pull(remote_dir: str, dest: Path, max_age: str | None) -> int:
    dest.mkdir(parents=True, exist_ok=True)
    cmd = ["rclone", "copy", remote_dir, str(dest), "--include", "*.pdf", "--transfers", "8"]
    # --all passes max_age=None → copy everything. (Google Drive rejects an absurd
    # --max-age like "1000y" with HTTP 400, so omit the flag entirely for a full sweep.)
    if max_age is not None:
        cmd[4:4] = ["--max-age", max_age]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"rclone copy failed: {cp.stderr.strip()}")
    return len(list(dest.rglob("*.pdf")))


def rclone_get_bib(remote: str, dest: Path) -> str | None:
    target = dest / BIB_NAME
    cp = run(["rclone", "copyto", f"{remote}/{BIB_NAME}", str(target)])
    return str(target) if cp.returncode == 0 and target.exists() else None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Incremental Paperpile->Readwise highlight sync")
    ap.add_argument("--max-age", help="rclone --max-age override (e.g. 7d, 48h). Default: since last run.")
    ap.add_argument("--all", action="store_true", help="Process the ENTIRE library (ignores modified-time window).")
    ap.add_argument("--dry-run", action="store_true", help="Extract and report; do NOT post to Readwise or update state.")
    ap.add_argument("--remote", default=DEFAULT_REMOTE, help=f"rclone remote:path of the Paperpile folder (default: {DEFAULT_REMOTE})")
    ap.add_argument("--keep-temp", action="store_true", help="Do not delete the temp download dir (debugging).")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")

    token = get_readwise_token()
    if not token and not args.dry_run:
        logger.error("No Readwise token (set READWISE_TOKEN or READWISE_TOKEN_FILE).")
        return 2

    max_age = None if args.all else compute_max_age(args)
    started = datetime.now(timezone.utc)
    tmp = Path(tempfile.mkdtemp(prefix="paperpile-rw-"))
    logger.info("window=%s  temp=%s", "ALL" if args.all else max_age, tmp)

    try:
        papers_dir = f"{args.remote}/{WATCH_SUBDIR}"
        n = rclone_pull(papers_dir, tmp / "pdfs", max_age)
        logger.info("pulled %d changed PDF(s)", n)
        if n == 0:
            if not args.dry_run:
                write_state(started)
            logger.info("nothing to sync.")
            return 0

        bib_path = rclone_get_bib(args.remote, tmp)
        bib_db = load_bibtex(bib_path) if bib_path else {}
        logger.info("bib entries with files: %d", len(bib_db))

        total_hl = total_files = errors = 0
        for pdf in sorted((tmp / "pdfs").rglob("*.pdf")):
            try:
                anns = extract_annotations(str(pdf))
            except Exception as e:
                logger.warning("extract failed %s: %s", pdf.name, e)
                errors += 1
                continue
            meta = get_metadata(pdf.name, bib_db)
            payload = build_readwise_payload(anns, meta)
            k = len(payload["highlights"])
            if k == 0:
                logger.debug("no highlights: %s", pdf.name)
                continue
            total_files += 1
            if args.dry_run:
                logger.info("[dry-run] %d highlights — %s", k, meta.get("title", pdf.name)[:70])
                total_hl += k
                continue
            res = sync_to_readwise(payload, token)
            if res["success"]:
                total_hl += res["count"]
                logger.info("synced %d — %s", res["count"], meta.get("title", pdf.name)[:70])
            else:
                errors += 1
                logger.error("readwise error for %s: %s", pdf.name, res["error"])

        logger.info("done: %d highlights across %d paper(s); %d error(s)", total_hl, total_files, errors)
        # Only advance the watermark if nothing errored (so failures get retried next run).
        if not args.dry_run and errors == 0:
            write_state(started)
        elif errors:
            logger.warning("errors occurred — state NOT advanced; will retry this window next run.")
        return 0 if errors == 0 else 1
    finally:
        if args.keep_temp:
            logger.info("kept temp: %s", tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
