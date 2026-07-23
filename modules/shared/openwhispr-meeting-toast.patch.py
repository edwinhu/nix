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

Anchored on the notification-specific call (the `this.notificationWindow.`
receiver) so the main-panel and preface calls are left alone, and asserted to
occur exactly the expected number of times so an upstream rework fails the Nix
build loudly instead of silently shipping an unpatched (broken) app.
"""
import sys

EXPECTED = 2  # setNotificationInteractivity() else-branch + the darwin-guarded call

path = sys.argv[1]
with open(path, "rb") as f:
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

with open(path, "wb") as f:
    f.write(blob.replace(OLD, NEW))

print(f"openwhispr meeting-toast patch: applied to {count} call(s)")
