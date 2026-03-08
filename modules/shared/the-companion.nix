# the-companion - Web UI for Claude Code agents
# npm package that requires bun as runtime
# Split into base (slow npm install, cached) and patched (fast, rebuilds on patch changes)
{ lib, buildNpmPackage, fetchurl, bun, makeWrapper, stdenv, python3 }:

let
  version = "0.72.0";

  # Base package: npm install + copy source. Only rebuilds when version/deps change.
  base = buildNpmPackage {
    pname = "the-companion-base";
    inherit version;

    src = fetchurl {
      url = "https://registry.npmjs.org/the-companion/-/the-companion-${version}.tgz";
      hash = "sha256-A7OtrZndGVoDTFfe3A/UfXf5KJRAAhC6dc6IHameIaU=";
    };

    npmDepsHash = "sha256-TEt/x1EW5Obxxjjr9SvK2l0FLBCSGkKXxWc8jY/hBBc=";

    unpackPhase = ''
      tar xzf $src --strip-components=1
    '';

    postPatch = ''
      cp ${./the-companion-package-lock.json} package-lock.json
    '';

    dontNpmBuild = true;
    npmInstallFlags = [ "--production" "--ignore-scripts" ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/the-companion
      cp -r . $out/lib/the-companion/
      runHook postInstall
    '';

    meta.description = "the-companion base (unpatched)";
  };

in stdenv.mkDerivation {
  pname = "the-companion";
  inherit version;

  # No source needed — we copy from the cached base
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper python3 ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/the-companion

    # Symlink everything from base, then selectively copy files we need to patch
    for f in ${base}/lib/the-companion/*; do
      ln -s "$f" $out/lib/the-companion/
    done

    # Replace symlinks with real copies for directories we patch
    rm $out/lib/the-companion/dist $out/lib/the-companion/server
    cp -r ${base}/lib/the-companion/dist $out/lib/the-companion/dist
    cp -r ${base}/lib/the-companion/server $out/lib/the-companion/server
    chmod -R u+w $out/lib/the-companion/dist $out/lib/the-companion/server

    # Replace upstream orange theme-color with Catppuccin Mocha Crust
    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail \
      '<meta name="theme-color" content="#d97757" />' \
      '<meta name="theme-color" content="#11111b" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="#eff1f5" media="(prefers-color-scheme: light)" />'

    # Inject Catppuccin Mocha theme overrides into index.html
    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail '</head>' '    <style>
      /* Catppuccin Mocha theme override */
      .dark {
        --color-cc-bg: #1e1e2e;        /* Base */
        --color-cc-fg: #cdd6f4;        /* Text */
        --color-cc-card: #181825;      /* Mantle */
        --color-cc-primary: #cba6f7;   /* Mauve */
        --color-cc-primary-hover: #b4befe; /* Lavender */
        --color-cc-user-bubble: #313244; /* Surface0 */
        --color-cc-border: #45475a40;  /* Surface1 + alpha */
        --color-cc-muted: #a6adc8;     /* Subtext0 */
        --color-cc-sidebar: #11111b;   /* Crust */
        --color-cc-input-bg: #181825;  /* Mantle */
        --color-cc-code-bg: #11111b;   /* Crust */
        --color-cc-code-fg: #cdd6f4;   /* Text */
        --color-cc-hover: #cdd6f40a;
        --color-cc-active: #cdd6f412;
        --color-cc-success: #a6e3a1;   /* Green */
        --color-cc-error: #f38ba8;     /* Red */
        --color-cc-warning: #f9e2af;   /* Yellow */
      }
      .dark .diff-file-header { background: #313244; }
      .dark .diff-line-add { background: #a6e3a114; }
      .dark .diff-line-del { background: #f38ba814; }
      .dark .diff-word-add { background: #a6e3a133; }
      .dark .diff-word-del { background: #f38ba833; }
      /* Maple Mono NF everywhere */
      :root {
        --font-sans: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --font-mono: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
        --default-font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --default-mono-font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
      body {
        font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
      }
      code, pre, kbd, samp, .font-mono, [class*="monospace"] {
        font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
    </style>
  </head>'

    # Fix Bun WebSocket ping timeout killing CLI connections (close code 1006)
    # Bun applies a ping timeout (max 16s, default 4s) even when idleTimeout is set,
    # causing abnormal closures when CLI doesn't respond to pings fast enough.
    # See: https://github.com/oven-sh/bun/issues/26554
    # sendPings must be inside the websocket: {} block (Bun API)
    # Keep top-level idleTimeout for HTTP; disable WS timeout + pings in websocket block
    substituteInPlace $out/lib/the-companion/server/index.ts \
      --replace-fail \
        'websocket: {' \
        'websocket: {
    idleTimeout: 0,
    sendPings: false,'

    # Patch ws-bridge.ts: stale socket guard + debounced disconnect notification
    # Uses Python for reliable multi-line replacement (sed breaks with nix indentation stripping)
    #
    # 1. handleCLIClose: guard against stale socket, then debounce the cli_disconnected
    #    broadcast by 5s. CLI cycles its WS every ~30s (code 1000). Without debounce,
    #    browsers see cli_disconnected/cli_connected flapping and handleBrowserOpen
    #    can trigger spurious relaunches during the brief cliSocket=null window.
    # 2. handleCLIOpen: cancel any pending disconnect debounce timer so browsers
    #    never see the disconnection if CLI reconnects within 5s.
    python3 - "$out/lib/the-companion/server/ws-bridge.ts" << 'PYEOF'
import sys
path = sys.argv[1]
code = open(path).read()

# Patch 1: Replace handleCLIClose body — stale guard + debounced disconnect
old_close = (
    "    session.cliSocket = null;\n"
    "    console.log(`[ws-bridge] CLI disconnected for session ''${sessionId}`);\n"
    "    this.broadcastToBrowsers(session, { type: \"cli_disconnected\" });\n"
    "\n"
    "    // Cancel any pending permission requests\n"
    "    for (const [reqId] of session.pendingPermissions) {\n"
    "      this.broadcastToBrowsers(session, { type: \"permission_cancelled\", request_id: reqId });\n"
    "    }\n"
    "    session.pendingPermissions.clear();"
)

new_close = "\n".join([
    "    // Guard: ignore close events from stale sockets (new WS opened before old closed)",
    "    if (session.cliSocket !== ws) {",
    '      console.log("[ws-bridge] Stale CLI WS closed for " + sessionId + ", ignoring");',
    "      return;",
    "    }",
    "    session.cliSocket = null;",
    "",
    "    // Debounce: delay disconnect notification by 5s.",
    "    // CLI cycles its WebSocket every ~30s (close code 1000). If we broadcast",
    "    // cli_disconnected immediately, browsers see flapping and handleBrowserOpen",
    "    // triggers relaunch attempts during the brief cliSocket=null window.",
    "    if (!(globalThis as any).__wsDisconnectTimers) (globalThis as any).__wsDisconnectTimers = new Map();",
    "    const _dt: Map<string, ReturnType<typeof setTimeout>> = (globalThis as any).__wsDisconnectTimers;",
    "    const _existing = _dt.get(sessionId);",
    "    if (_existing) clearTimeout(_existing);",
    "    _dt.set(sessionId, setTimeout(() => {",
    "      _dt.delete(sessionId);",
    "      if (session.cliSocket) return; // CLI reconnected during grace period",
    '      console.log("[ws-bridge] CLI disconnect confirmed for " + sessionId);',
    '      this.broadcastToBrowsers(session, { type: "cli_disconnected" });',
    "      for (const [reqId] of session.pendingPermissions) {",
    '        this.broadcastToBrowsers(session, { type: "permission_cancelled", request_id: reqId });',
    "      }",
    "      session.pendingPermissions.clear();",
    "    }, 5000));",
])

assert old_close in code, "handleCLIClose pattern not found in ws-bridge.ts"
code = code.replace(old_close, new_close)

# Patch 2: In handleCLIOpen, cancel pending disconnect timer after setting cliSocket
old_open = "    session.cliSocket = ws;\n    console.log(`[ws-bridge] CLI connected for session ''${sessionId}`);"
new_open = "\n".join([
    "    session.cliSocket = ws;",
    "    // Cancel any pending disconnect debounce timer — CLI reconnected in time",
    "    const _dt2: Map<string, ReturnType<typeof setTimeout>> = (globalThis as any).__wsDisconnectTimers || new Map();",
    "    if (_dt2.has(sessionId)) {",
    "      clearTimeout(_dt2.get(sessionId)!);",
    "      _dt2.delete(sessionId);",
    '      console.log("[ws-bridge] CLI reconnected for " + sessionId + " (disconnect debounce cancelled)");',
    "    } else {",
    '      console.log("[ws-bridge] CLI connected for session " + sessionId);',
    "    }",
])
assert old_open in code, "handleCLIOpen pattern not found in ws-bridge.ts"
code = code.replace(old_open, new_open)

open(path, "w").write(code)
print("[patch] ws-bridge.ts: stale socket guard + debounced disconnect + timer cancel in open")
PYEOF

    # Log WebSocket close events with close code to detect cycling
    substituteInPlace $out/lib/the-companion/server/index.ts \
      --replace-fail \
        'close(ws: ServerWebSocket<SocketData>) {' \
        'close(ws: ServerWebSocket<SocketData>, code?: number, reason?: string) {
      console.log("[ws-close]", ws.data.kind, "code=" + code);'

    # Grace period for CLI WebSocket reconnection (code 1000)
    # Claude CLI periodically closes and re-establishes its WebSocket.
    # Without a grace period, handleBrowserOpen sees cliSocket=null and
    # triggers a relaunch, causing duplicate CLI processes and output replay.
    # IMPORTANT: Add to relaunchingSet BEFORE the await so concurrent browser
    # connections (multiple tabs) are blocked during the grace period.
    # Previous bug: set was added AFTER the 10s await, so parallel calls all
    # passed the guard and spawned duplicate --resume CLIs.
    substituteInPlace $out/lib/the-companion/server/index.ts \
      --replace-fail \
        'if (relaunchingSet.has(sessionId)) return;' \
        'if (relaunchingSet.has(sessionId)) return;
    relaunchingSet.add(sessionId);
    // Grace period: CLI does normal code-1000 WS reconnection cycles.
    // Wait 10s, then check if CLI process is still alive or WS reconnected.
    await new Promise(r => setTimeout(r, 10000));
    if (wsBridge.isCliConnected(sessionId)) { relaunchingSet.delete(sessionId); return; }
    const _chk = launcher.getSession(sessionId);
    if (_chk && (_chk.state === "connected" || _chk.state === "running")) { relaunchingSet.delete(sessionId); return; }
    // Also check if the OS process is still alive by PID (signal 0).
    // Session state/WS can be stale during cycling, but PID check is definitive.
    if (_chk?.pid) { try { process.kill(_chk.pid, 0); relaunchingSet.delete(sessionId); return; } catch {} }'

    # Replace hardcoded orange accent (#d97757) with Catppuccin Mauve in CSS
    for cssfile in $out/lib/the-companion/dist/assets/index-*.css; do
      sed -i 's/#d97757/#cba6f7/g' "$cssfile"
    done

    # Patch terminal dark-mode background to Catppuccin Mocha Base
    for jsfile in $out/lib/the-companion/dist/assets/index-*.js; do
      sed -i 's/#141413/#1e1e2e/g' "$jsfile"
      # Set terminal font to Maple Mono NF at 16px
      sed -i "s/fontFamily:\"monospace\",fontSize:15/fontFamily:\"'Maple Mono NF', monospace\",fontSize:16/g" "$jsfile"
    done

    mkdir -p $out/bin
    makeWrapper ${bun}/bin/bun $out/bin/the-companion \
      --add-flags "$out/lib/the-companion/bin/cli.ts" \
      --set NODE_ENV production

    runHook postInstall
  '';

  meta = {
    description = "Web UI for launching and interacting with Claude Code agents";
    homepage = "https://github.com/The-Vibe-Company/companion";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "the-companion";
  };
}
