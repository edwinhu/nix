# Chromium configuration shared by the Omarchy hosts (x86 `omarchy`, aarch64
# `alarm`). Both run Arch's /usr/bin/chromium, so the flags file and the
# root-owned /etc policies below apply identically on each.
{ ... }:

{
  # Chromium flags (Arch's chromium wrapper appends every line to each launch).
  # Reproduces the Omarchy defaults and adds browser-wide CDP: the main Default
  # profile (already logged in) owns the debug endpoint on :9222, and every
  # app window (Morgen, etc. launched via omarchy-launch-webapp) is a page on
  # that one endpoint — so morgen-cli, which probes here after finding no
  # Electron app, reads tokens from the live session, no per-app profile or
  # manual re-login. force = it seeds a real file at install time, overwriting
  # whatever an Omarchy migration last left there.
  #
  # REQUIRES a managed policy: Chromium 136+ silently IGNORES
  # --remote-debugging-port on the *default* profile (anti-cookie-theft
  # mitigation), so the browser-wide CDP above is dead without it — :9222 never
  # opens. Re-enable it with a root-owned system policy (one-time; outside
  # home-manager's /etc scope, so not declarative here):
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-managed-policy.json \
  #     /etc/chromium/policies/managed/enable-remote-debugging.json
  # (RemoteDebuggingAllowed=true). Verify: curl -s localhost:9222/json/version.
  # SECURITY: this leaves a CDP port open on localhost whenever Chromium runs;
  # any local process can drive the browser. Acceptable on a personal machine;
  # scoped to this host only (not in shared dotfiles).
  #
  # Extensions are ALSO force-installed via a root-owned managed policy (same
  # /etc scope, so not declarative here) — Chromium sync is off, so this is the
  # only way the profile's extensions come back on a fresh machine. They
  # auto-install + auto-update from the Web Store and can't be removed by hand
  # while the policy is present. IDs = 1Password, Paperpile, Vimium, Tampermonkey,
  # Readwise, AdGuard, Perma.cc, Claude, uBlock Origin Lite, Raindrop.io,
  # Google Scholar PDF Reader, Google Scholar Button (copy-url is separate —
  # loaded unpacked via --load-extension below):
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-extensions-policy.json \
  #     /etc/chromium/policies/managed/extensions.json
  # Verify: chrome://policy (Reload policies) shows ExtensionInstallForcelist.
  #
  # Tampermonkey userscripts are PROVISIONED declaratively — a FOURTH policy.
  # Tampermonkey ships storage.managed_schema (schema.json in its bundle) with a
  # single key, `jsonImport`: a list of {url, hash} pointing at a Tampermonkey
  # JSON export. On startup it fetches each url, verifies the hash, installs the
  # scripts, and records the hash so it only ever applies once. That closes the
  # last manual step — a fresh machine ends up with the userscripts already
  # installed, no clicking through Tampermonkey's install page:
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-tampermonkey-policy.json \
  #     /etc/chromium/policies/managed/tampermonkey.json
  #
  # `source` MUST be BASE64 of the script's UTF-8 bytes, not raw text. The
  # installer does `Qe(Xe(source))` = decodeURIComponent(escape(atob(source))),
  # and that atob sits OUTSIDE its try/catch. Raw text throws
  # InvalidCharacterError (immediately, if the script contains any character
  # above U+00FF -- an em-dash in a @name is enough), the rejection escapes the
  # extension's init IIFE uncaught, and provisioning dies in total silence after
  # the "start downloading" line: no error, no scripts, no success marker, and a
  # half-initialised extension. Cost most of an evening and three independent
  # investigations to find; the first two theories (offscreen/XHR transport, then
  # a stuck request) were both wrong.
  #
  # The hash is NOT a plain sha256 of the file. Tampermonkey walks the parsed
  # JSON and hashes recursively: leaves as sha256("<typeof>:<value>"), arrays and
  # objects as sha256 of their children's hashes concatenated, object keys sorted
  # and the keys themselves NOT hashed. Prefix "1:" is the format version. So
  # reformatting the JSON is fine, but changing any value means recomputing.
  # Regenerate with scripts/tampermonkey-provisioning-hash.py.
  #
  # The bundle is only for FIRST install. Each script carries @updateURL pointing
  # at its own gist, so it self-updates afterwards and the bundle can go stale
  # without harm — it is a seed, not a sync channel.

  # Force-installing extensions has a NON-OBVIOUS side effect that needs a THIRD
  # policy. DeveloperToolsAvailability defaults to
  # DisallowedForForceInstalledExtensions, so the moment an extension arrives via
  # the forcelist above, ALL CDP attach to that extension's service worker is
  # refused — including our own tooling. Concretely: readwise-reader-tools could
  # still *find* the Readwise extension SW target but every message round-trip
  # timed out ("Timeout communicating with extension service worker"), 14/14
  # saves silently falling back to the weaker manual-extraction path. It broke on
  # 2026-07-15, the day the Readwise ID was added to the forcelist, and looked
  # exactly like the extension auth drift we'd seen before — hence the long
  # misdiagnosis. Root cause + probe: readwise-reader-tools
  # docs/investigations/2026-07-21_extension-save-blocked-by-forcelist-policy.md
  #   sudo install -Dm644 hosts/linux/omarchy/files/chromium-devtools-policy.json \
  #     /etc/chromium/policies/managed/devtools-availability.json
  # Then: systemctl --user restart chrome-cdp
  # Verify: chrome://policy shows DeveloperToolsAvailability=1 (Allowed for all),
  # and CDP can attach to a force-installed extension's SW target.
  # NOTE the ordering dependency — adding ANY new extension to the forcelist
  # without this policy present re-breaks CDP access to it.
  xdg.configFile."chromium-flags.conf" = {
    force = true;
    text = ''
      --ozone-platform=wayland
      --ozone-platform-hint=wayland
      # WebRTCPipeWireCapturer is an Omarchy default and MUST stay: under Wayland
      # it is what lets Chromium enumerate screens/windows for sharing via the
      # PipeWire portal. Without it the Zoom web app's "Share Screen" finds no
      # sources. This file REPLACES Omarchy's (force = true), so anything in
      # /usr/share/omarchy/config/chromium-flags.conf that is not restated here
      # is silently lost -- diff against that file after an Omarchy upgrade.
      --enable-features=TouchpadOverscrollHistoryNavigation,WebRTCPipeWireCapturer
      # Expose the renderer a11y tree so `hints` can read real elements instead
      # of falling back to opencv edge-detection (same reason the Electron
      # desktop entries pass it, and why dconf sets toolkit-accessibility).
      --force-renderer-accessibility
      # ABSOLUTE PATHS, NOT ~. The Arch chromium wrapper is a C binary that
      # splits this file with g_shell_parse_argv ("shell quoting rules apply but
      # no further parsing is performed" -- its own --help). That does NOT expand
      # tilde, so `--load-extension=~/...` reaches Chromium with a literal ~ and
      # silently loads nothing. copy-url had been specified that way since it was
      # added and had NEVER loaded: the Default profile's extension list showed no
      # location=4 (command-line) entry at all, only the forcelist ones. Nothing
      # errors -- the flag is simply ignored -- which is why it went unnoticed.
      #
      # If a second unpacked extension is ever added here it MUST be appended
      # comma-separated to this same flag -- Chromium honours only the LAST
      # --load-extension, so a second line would silently drop copy-url.
      #
      # Paths are /usr/share/omarchy, NOT ~/.local/share/omarchy. Quattro made
      # /usr/share/omarchy canonical and ~/.local/share/omarchy a symlink to it.
      # Both resolve, but omarchy-upgrade-to-quattro's
      # repair_chromium_copy_url_extension_flags rewrites the legacy spelling to
      # the canonical one -- and since this file is a read-only /nix/store
      # symlink, that write dies with PermissionError and aborts the entire user
      # transition. It is guarded by a grep for the legacy path, so emitting the
      # canonical path makes the upgrade skip this file untouched.
      #
      # yt-dlp and whatsapp-slim are declared for the same reason: migrations
      # 1780517689 and 1785543725 otherwise `sed -i --follow-symlinks` them in
      # and fail the migration queue. Each greps its own extensions/ path first,
      # so declaring them here makes those migrations no-ops. Any FUTURE Omarchy
      # migration that edits this file needs the same treatment.
      --load-extension=/usr/share/omarchy/default/chromium/extensions/copy-url,/usr/share/omarchy/default/chromium/extensions/yt-dlp,/usr/share/omarchy/default/chromium/extensions/whatsapp-slim
      # Google account sign-in. Arch's chromium ships without Google's OAuth
      # credentials, so signing in silently does nothing; these are the ones
      # omarchy-install-chromium-google-account appends. That script writes with
      # a bare `>>` and has no `set -e`, so against this read-only /nix/store
      # symlink it fails with "Permission denied" and STILL prints "Now you can
      # login" -- declaring the flags here is the only thing that actually works.
      # It guards each line with `grep -qxF`, so these exact strings make it a
      # no-op. Keep them byte-identical to the script's if it ever changes them.
      --oauth2-client-id=77185425430.apps.googleusercontent.com
      --oauth2-client-secret=OTJgUOQcT7lO7GsGZq2G4IlT
      # Pin the os_crypt backend (Omarchy migration 1784508556). On Hyprland the
      # xdg-desktop-portal Secret backend has no provider, so Chromium can fall
      # back to the 'basic' v10 store; that makes cookies and passwords encrypted
      # under the gnome-libsecret v11 key undecryptable and silently logs you out
      # of everything.
      --password-store=gnome-libsecret
      --remote-debugging-port=9222
      --remote-allow-origins=*
      # Keep the visible-but-unfocused browser window's ACTIVE tab reachable. In
      # a tiling WM the browser is often visible but not the focused window;
      # Chromium's occlusion detection then treats it as occluded and freezes its
      # active tab after ~5s, and a frozen tab rejects new CDP connections — so
      # vimium-toggle (Hyper+V) can't reach the tab you're looking at until you
      # refocus. This single flag stops that occlusion-backgrounding while leaving
      # genuinely-hidden background tabs free to freeze AND discard normally, so
      # CPU/battery + RAM savings are preserved for tabs you're not looking at.
      --disable-backgrounding-occluded-windows
    '';
  };
}
