#!/usr/bin/env python3
"""Seed the Vimium 'open popup' shortcut (Alt+V) into Chromium's Preferences.

Chromium stores extension keyboard shortcuts in
  ~/.config/chromium/Default/Preferences  ->  extensions.commands
as a plain (non-HMAC-signed) JSON map keyed by "linux:<Accelerator>". There is
no managed-policy or manifest path for this, so home-manager seeds it here.

Binds Alt+V to Vimium's `_execute_action` (opens the browser-action popup), the
per-site enable/disable + excluded-keys UI — an opt-in "vim mode" toggle.

Safety / idempotency:
  - Skips if Chromium is running (it rewrites Preferences on exit and would
    clobber our edit). The activation wrapper also guards on this.
  - No-op if Vimium is ALREADY bound to _execute_action under any key, so a
    later manual rebind in chrome://extensions/shortcuts is respected.
  - No-op if "linux:Alt+V" is already claimed by a different extension.
  - Atomic write (temp file + os.replace).
"""
import json
import os
import sys
import tempfile

VIMIUM_ID = "dbepggeogbaibhgnhhndojpepiihcmeb"
ACCELERATOR = "linux:Alt+V"
PREFS = os.path.expanduser("~/.config/chromium/Default/Preferences")

if not os.path.exists(PREFS):
    print(f"seed-vimium-shortcut: {PREFS} not found; skipping")
    sys.exit(0)

with open(PREFS, "r", encoding="utf-8") as fh:
    prefs = json.load(fh)

commands = prefs.setdefault("extensions", {}).setdefault("commands", {})

# Respect an existing Vimium action binding (e.g. user rebound it by hand).
for key, spec in commands.items():
    if spec.get("extension") == VIMIUM_ID and spec.get("command_name") == "_execute_action":
        print(f"seed-vimium-shortcut: Vimium already bound at {key}; skipping")
        sys.exit(0)

existing = commands.get(ACCELERATOR)
if existing and existing.get("extension") != VIMIUM_ID:
    print(
        f"seed-vimium-shortcut: {ACCELERATOR} already used by "
        f"{existing.get('extension')}; skipping to avoid clobber"
    )
    sys.exit(0)

commands[ACCELERATOR] = {
    "command_name": "_execute_action",
    "extension": VIMIUM_ID,
    "global": False,
}

d = os.path.dirname(PREFS)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".Preferences.seed.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(prefs, fh, separators=(",", ":"))
    os.replace(tmp, PREFS)
except BaseException:
    os.unlink(tmp)
    raise

print(f"seed-vimium-shortcut: bound Vimium _execute_action to {ACCELERATOR}")
