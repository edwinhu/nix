#!/usr/bin/env python3
"""Swap OpenWhispr's Linux meeting-audio detector for an app-aware one.

See modules/shared/openwhispr.nix for the rationale, and
modules/shared/openwhispr-audio-activity-detector.js for the replacement itself.
In short: upstream fires "It sounds like you're in a meeting" after two seconds
of ANY microphone stream, with no idea which application opened it, and never
notices a call that was already running when the app started.

`src/helpers/audioActivityDetector.js` ships UNMINIFIED inside app.asar, so the
fix is a whole-file replacement rather than a byte patch. The replacement is
longer than the original, which means every subsequent file offset moves and the
archive must be REPACKED (unlike the same-length toast substitution, which can
be done in place). We therefore rewrite app.asar from its own header: same
entries, same order, same contents, only recomputed offsets — and a recomputed
`integrity` block for the one file we replace.

Files stored OUTSIDE the archive (`unpacked: true`, i.e. the native modules in
app.asar.unpacked) carry no offset and are left untouched, as are symlink
entries; only real in-archive payloads are re-emitted.

We pin the sha256 of the file we are replacing. A version bump that touches
upstream's detector changes that hash and fails the build here, rather than
silently reverting to unattributed detection or dropping an upstream fix.

Usage: openwhispr-meeting-detection.patch.py <extracted-app-root> <replacement.js>
"""
import hashlib
import json
import os
import struct
import sys

root, replacement_path = sys.argv[1], sys.argv[2]

TARGET = "/src/helpers/audioActivityDetector.js"
# sha256 of upstream's src/helpers/audioActivityDetector.js as shipped in 1.7.5,
# which is what modules/shared/openwhispr-audio-activity-detector.js was forked
# from. Re-fork and update this on a version bump.
EXPECTED_SHA256 = "cf09b32404722abe3af9238f65beea6d0ac3f428123142c5bb5db84c0abc0c19"

# asar's integrity block: whole-file sha256 plus per-block sha256 over 4 MiB
# chunks. Only enforced with the EnableEmbeddedAsarIntegrityValidation fuse on
# (asserted off by the toast patch), but we keep it correct for the file we
# rewrite so the archive stays self-consistent.
BLOCK_SIZE = 4 * 1024 * 1024

asar_path = os.path.join(root, "resources", "app.asar")
with open(asar_path, "rb") as f:
    blob = f.read()

header_buf_len = struct.unpack("<I", blob[4:8])[0]
json_len = struct.unpack("<I", blob[12:16])[0]
header = json.loads(blob[16 : 16 + json_len].decode("utf8"))
data_start = 8 + header_buf_len

# Walk the entry tree in a fixed order, collecting the payload of every real
# in-archive file. Order is preserved on write so the repacked archive differs
# from the original only where intended.
entries = []


def walk(node, path):
    for name, child in node.get("files", {}).items():
        child_path = f"{path}/{name}"
        if "files" in child:
            walk(child, child_path)
        elif "offset" in child:
            entries.append((child_path, child))


walk(header, "")

target_entry = next((entry for p, entry in entries if p == TARGET), None)
if target_entry is None:
    sys.exit(
        f"openwhispr meeting-detection patch: {TARGET} not found in app.asar. "
        f"Upstream moved or renamed the audio detector — re-verify the fix "
        f"against the new version before building."
    )

offset = data_start + int(target_entry["offset"])
original = blob[offset : offset + target_entry["size"]]
actual_sha = hashlib.sha256(original).hexdigest()
if actual_sha != EXPECTED_SHA256:
    sys.exit(
        f"openwhispr meeting-detection patch: {TARGET} is not the version this "
        f"fix was forked from (expected sha256 {EXPECTED_SHA256}, found "
        f"{actual_sha}). Upstream changed the audio detector — re-fork "
        f"modules/shared/openwhispr-audio-activity-detector.js from the new "
        f"file and update EXPECTED_SHA256."
    )

with open(replacement_path, "rb") as f:
    replacement = f.read()

# Re-emit every payload at a freshly assigned offset.
chunks = []
cursor = 0
for path, entry in entries:
    if path == TARGET:
        payload = replacement
    else:
        start = data_start + int(entry["offset"])
        payload = blob[start : start + entry["size"]]

    entry["offset"] = str(cursor)
    entry["size"] = len(payload)
    if "integrity" in entry and path == TARGET:
        entry["integrity"] = {
            "algorithm": "SHA256",
            "hash": hashlib.sha256(payload).hexdigest(),
            "blockSize": BLOCK_SIZE,
            "blocks": [
                hashlib.sha256(payload[i : i + BLOCK_SIZE]).hexdigest()
                for i in range(0, max(len(payload), 1), BLOCK_SIZE)
            ],
        }

    chunks.append(payload)
    cursor += len(payload)

# asar container: [uint32 4][uint32 header_pickle_len] then the header pickle
# ([uint32 payload_len][uint32 json_len][json][pad to 4]), then the payloads.
new_json = json.dumps(header, separators=(",", ":")).encode("utf8")
padding = (4 - len(new_json) % 4) % 4
header_pickle = struct.pack("<I", len(new_json)) + new_json + b"\0" * padding
header_pickle = struct.pack("<I", len(header_pickle)) + header_pickle

with open(asar_path, "wb") as f:
    f.write(struct.pack("<II", 4, len(header_pickle)))
    f.write(header_pickle)
    for chunk in chunks:
        f.write(chunk)

print(
    f"openwhispr meeting-detection patch: replaced {TARGET} "
    f"({len(original)} -> {len(replacement)} bytes), repacked "
    f"{len(entries)} archive entries"
)
