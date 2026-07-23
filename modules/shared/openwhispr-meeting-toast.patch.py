#!/usr/bin/env python3
"""Keep OpenWhispr's meeting-recording toast clickable on Linux/wlroots.

See modules/shared/openwhispr.nix for the full rationale. In short: the toast
(a custom transparent Electron BrowserWindow) toggles itself click-through on
mouse-leave via `this.notificationWindow.setIgnoreMouseEvents(true, { forward:
true })`. On wlroots (Hyprland/Sway) forwarded mouse-move events are never
delivered to a click-through surface, so the mouseenter that would flip it back
to interactive can't fire and the toast sticks click-through — Start/Dismiss stop
responding (upstream issue #840, unfixed as of 1.7.6).

Fix: neutralize that call so the toast stays interactive. We edit the packed
`app.asar` blob in place with a byte-for-byte same-length substitution, so every
file offset in the asar header stays valid and the archive needs no repacking
(the native unpacked modules alongside it are untouched). `false` followed by
whitespace inside the call's parentheses is valid JS and identical in length to
the original `true, { forward: true }` argument list.

Editing the blob invalidates the per-file `integrity` hashes electron-builder
embeds in the asar header. That is only enforced when Electron's
`EnableEmbeddedAsarIntegrityValidation` fuse is on (and even then not on Linux
today), so before patching we ASSERT that fuse is not enabled in the bundled
Electron binary. If a future version flips it on, the build fails here loudly
rather than shipping an app that rejects its own (edited) asar at startup.

Both the asar substitution and the fuse check are anchored/asserted to a fixed
shape, so an upstream rework fails the Nix build instead of silently shipping an
unpatched (broken) or integrity-rejected app.

Usage: openwhispr-meeting-toast.patch.py <extracted-app-root>
"""
import os
import sys

root = sys.argv[1]

# ---------------------------------------------------------------------------
# 1. Assert Electron's asar-integrity fuse is not enabled.
#
# The fuse wire is a magic sentinel followed by: version byte, fuse-count byte,
# then one state byte per fuse ('0'=disabled, '1'=enabled, 'r'=removed/inert).
# EnableEmbeddedAsarIntegrityValidation is index 4 of the stable FuseV1Options
# enum. Verified for 1.7.5: the wire lives in `open-whispr-app`, and index 4 is
# '0' (disabled).
# ---------------------------------------------------------------------------
FUSE_SENTINEL = b"dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
INTEGRITY_FUSE_INDEX = 4
FUSE_ENABLED = 0x31  # '1'
FUSE_BINARIES = ["open-whispr-app", "open-whispr"]

checked = False
for name in FUSE_BINARIES:
    path = os.path.join(root, name)
    if not os.path.exists(path):
        continue
    with open(path, "rb") as f:
        data = f.read()
    idx = data.find(FUSE_SENTINEL)
    if idx < 0:
        continue
    checked = True
    off = idx + len(FUSE_SENTINEL)
    count = data[off + 1]
    if count <= INTEGRITY_FUSE_INDEX:
        sys.exit(
            f"openwhispr fuse check: {name} exposes only {count} fuses, cannot "
            f"read EnableEmbeddedAsarIntegrityValidation (index "
            f"{INTEGRITY_FUSE_INDEX}). Electron fuse layout changed — re-verify "
            f"before building."
        )
    state = data[off + 2 + INTEGRITY_FUSE_INDEX]
    if state == FUSE_ENABLED:
        sys.exit(
            f"openwhispr fuse check: EnableEmbeddedAsarIntegrityValidation is ON "
            f"in {name}. The in-place asar byte-patch invalidates the embedded "
            f"integrity hashes, so Electron would reject the edited archive at "
            f"startup. Repack the asar (regenerating hashes) instead of "
            f"byte-patching, or drop this fix."
        )
    break

if not checked:
    sys.exit(
        "openwhispr fuse check: no Electron fuse wire found in any of "
        f"{FUSE_BINARIES}. The bundle layout changed — re-verify that asar "
        "integrity validation is disabled before relying on the byte-patch."
    )

# ---------------------------------------------------------------------------
# 2. Patch the packed app.asar blob in place (same-length substitution).
# ---------------------------------------------------------------------------
EXPECTED = 2  # setNotificationInteractivity() else-branch + the darwin-guarded call

asar_path = os.path.join(root, "resources", "app.asar")
with open(asar_path, "rb") as f:
    blob = f.read()

OLD = b"this.notificationWindow.setIgnoreMouseEvents(true, { forward: true })"
# Same byte length: "(true, { forward: true })" (25) -> "(false" + spaces + ")" (25).
NEW = b"this.notificationWindow.setIgnoreMouseEvents(false                  )"
assert len(OLD) == len(NEW), (len(OLD), len(NEW))

count = blob.count(OLD)
if count != EXPECTED:
    sys.exit(
        f"openwhispr meeting-toast patch: expected {EXPECTED} occurrences of the "
        f"notification setIgnoreMouseEvents(forward) call, found {count}. The "
        f"upstream source changed — re-verify the fix against the new version "
        f"before building."
    )

with open(asar_path, "wb") as f:
    f.write(blob.replace(OLD, NEW))

print(
    f"openwhispr meeting-toast patch: integrity fuse off; applied to {count} call(s)"
)
