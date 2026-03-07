# the-companion - Web UI for Claude Code agents
# npm package that requires bun as runtime
# Split into base (slow npm install, cached) and patched (fast, rebuilds on patch changes)
{ lib, buildNpmPackage, fetchurl, bun, makeWrapper, stdenv }:

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

  nativeBuildInputs = [ makeWrapper ];

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

    # Fix WS close race condition: when CLI opens a new WS before the old one
    # closes, handleCLIClose unconditionally nulls cliSocket, clobbering the
    # new socket reference. This makes handleBrowserOpen see "backend is dead"
    # and trigger a spurious relaunch. Fix: only null if closing the CURRENT socket.
    sed -i '/handleCLIClose/,/session\.cliSocket = null;/{
      s|session\.cliSocket = null;|if (session.cliSocket !== ws) { console.log("[ws-bridge] Stale CLI WS closed for " + sessionId + ", ignoring"); return; }\n    session.cliSocket = null;|
    }' $out/lib/the-companion/server/ws-bridge.ts

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
