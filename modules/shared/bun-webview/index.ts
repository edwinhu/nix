// Shared Bun.WebView helpers. Zero runtime dependencies by design.
//
// The safety property this module exists to enforce: Bun's chrome backend
// DEFAULTS to discovering an already-running Chrome (via each profile's
// DevToolsActivePort file) and opening tabs in it. For a helper library that
// would mean silently driving the user's logged-in browser. `openView` pins
// `backend.url = false` -- always spawn -- and attaching is `attachView`, which
// a caller has to name deliberately.

type WebView = InstanceType<typeof Bun.WebView>;

const CHROMIUM_CANDIDATES = [
  "chromium",
  "chromium-browser",
  "google-chrome-stable",
  "chrome",
] as const;

export interface OpenViewOptions {
  url?: string;
  width?: number;
  height?: number;
  headless?: boolean;
  /** A directory for a persistent profile. Omitted means a throwaway one. */
  dataStore?: string | { directory: string } | "ephemeral";
  /** Extra Chrome launch flags, appended after Bun's defaults. */
  argv?: string[];
  console?: unknown;
}

export interface WaitForOptions {
  timeoutMs?: number;
  intervalMs?: number;
}

export interface RenderHtmlToPngOptions {
  width?: number;
  height?: number;
  /** Where to write the PNG. A temp file is used when omitted; never deleted. */
  path?: string;
}

export interface RenderHtmlToPngResult {
  path: string;
  width: number;
  height: number;
}

export interface CdpTarget {
  id: string;
  type: string;
  title: string;
  url: string;
  webSocketDebuggerUrl: string;
}

/**
 * The first Chrome-family browser on PATH. Chromium is the Arch system package
 * at /usr/bin/chromium and is deliberately not a nix package on this host, so
 * resolving from PATH at runtime is the design rather than a shortcut.
 */
export function resolveChromium(): string {
  for (const name of CHROMIUM_CANDIDATES) {
    // Bun.which() reads the PATH captured at startup unless one is passed
    // explicitly, so a caller (or a test) that edits process.env.PATH would
    // otherwise be ignored.
    const found = Bun.which(name, { PATH: process.env.PATH ?? "" });
    if (found) return found;
  }
  throw new Error(
    `bun-webview: no Chrome-family browser on PATH. Looked for ` +
      `${CHROMIUM_CANDIDATES.join(", ")}. Install one (on Arch: pacman -S chromium) ` +
      `or put it on PATH.`,
  );
}

function normalizeDataStore(
  dataStore: OpenViewOptions["dataStore"],
): "ephemeral" | { directory: string } {
  if (dataStore === undefined || dataStore === "ephemeral") return "ephemeral";
  if (typeof dataStore === "string") return { directory: dataStore };
  return dataStore;
}

/**
 * What `view.cdp()` can and cannot do, measured 2026-08-24 against bun 1.4.0 --
 * both of these cost an afternoon to find and one of them fails SILENTLY:
 *
 *   - Commands work, including `Target.getTargets` and `Target.createTarget`.
 *   - EVENTS work: enable the domain (`Page.enable`, `Network.enable`, ...) and
 *     they arrive via `view.addEventListener("Page.frameNavigated", fn)`.
 *   - Routing a command to ANOTHER target by `sessionId` DOES NOT WORK. The
 *     parameter is accepted and ignored: `Target.attachToTarget` hands back a
 *     real sessionId, and `Runtime.evaluate` with it still evaluates in THIS
 *     view. It returns a plausible wrong answer rather than throwing.
 *
 *   - A second `attachView` IN THE SAME PROCESS silently binds to the FIRST
 *     view's page. Measured: a title written through a view attached to /bbb
 *     landed on /aaa. Same shape as the sessionId bug -- a plausible wrong
 *     answer, never a throw -- one layer up.
 *   - Two `openView` calls in one process ARE bound correctly, and share one
 *     browser process.
 *   - `Runtime.evaluate` with an explicit `contextId` DOES route to that
 *     isolated world, per frame. contextId is within-session, so the sessionId
 *     breakage does not touch it.
 *
 * So: multi-tab work you SPAWN is fine in one process. Multi-tab work you
 * ATTACH needs ONE OS PROCESS PER TARGET -- `listTargets(port)` for the
 * webSocketDebuggerUrl, then a separate `bun` child per url, each attaching
 * exactly once. "One view per target" is necessary but NOT sufficient.
 */

/**
 * Open a view in a browser this process spawns itself. Never attaches to a
 * running one: `backend.url === false` skips Bun's auto-detect entirely.
 */
export async function openView(opts: OpenViewOptions = {}): Promise<WebView> {
  const view = new Bun.WebView({
    ...(opts.url === undefined ? {} : { url: opts.url }),
    ...(opts.width === undefined ? {} : { width: opts.width }),
    ...(opts.height === undefined ? {} : { height: opts.height }),
    ...(opts.console === undefined ? {} : { console: opts.console as never }),
    headless: opts.headless ?? true,
    dataStore: normalizeDataStore(opts.dataStore),
    backend: {
      type: "chrome",
      path: resolveChromium(),
      url: false,
      ...(opts.argv === undefined ? {} : { argv: opts.argv }),
    },
  } as never) as WebView;

  // An initial `url` navigates before the constructor returns; every later
  // operation on the view waits for that navigation and surfaces its failure,
  // so there is nothing to await here. Probing eagerly races the CDP session
  // setup and fails with "'Runtime.evaluate' wasn't found".
  return view;
}

/** Reject unless a WebSocket handshake against `wsUrl` actually completes. */
function probeWebSocket(wsUrl: string, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let socket: WebSocket;
    let settled = false;
    const finish = (err?: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket?.close();
      } catch {
        // already closing
      }
      err ? reject(err) : resolve();
    };
    const timer = setTimeout(
      () => finish(new Error(`timed out after ${timeoutMs}ms`)),
      timeoutMs,
    );
    try {
      socket = new WebSocket(wsUrl);
    } catch (err) {
      finish(err instanceof Error ? err : new Error(String(err)));
      return;
    }
    socket.onopen = () => finish();
    socket.onerror = (event: unknown) =>
      finish(new Error((event as { message?: string })?.message ?? "connection error"));
    socket.onclose = (event: unknown) =>
      finish(new Error(`closed with code ${(event as { code?: number })?.code ?? "unknown"}`));
  });
}

/**
 * The explicit opposite of openView: drive a browser that is ALREADY running,
 * named by its DevTools WebSocket URL. Reachability is checked here rather than
 * left to Bun, which reuses a Chrome this process already spawned and would
 * otherwise accept a dead endpoint silently.
 */
export async function attachView(
  wsUrl: string,
  opts: Omit<OpenViewOptions, "argv"> = {},
): Promise<WebView> {
  if (typeof wsUrl !== "string" || !/^wss?:\/\//.test(wsUrl)) {
    throw new Error(
      `bun-webview: attachView needs a ws:// or wss:// DevTools endpoint, got ${JSON.stringify(wsUrl)}`,
    );
  }
  try {
    await probeWebSocket(wsUrl, 10_000);
  } catch (err) {
    throw new Error(
      `bun-webview: could not connect to the DevTools endpoint ${wsUrl}: ` +
        `${err instanceof Error ? err.message : String(err)}`,
    );
  }

  // `url` cannot be combined with `path` or `argv` -- it names the browser.
  return new Bun.WebView({
    ...(opts.url === undefined ? {} : { url: opts.url }),
    ...(opts.width === undefined ? {} : { width: opts.width }),
    ...(opts.height === undefined ? {} : { height: opts.height }),
    ...(opts.console === undefined ? {} : { console: opts.console as never }),
    headless: opts.headless ?? true,
    backend: { type: "chrome", url: wsUrl },
  } as never) as WebView;
}

/**
 * The targets a DevTools HTTP endpoint reports. Out-of-band discovery: the
 * WebView surface has no Target.* helper, and a popup opened by a page is a
 * separate target that only shows up here.
 */
export async function listTargets(port: number | string): Promise<CdpTarget[]> {
  const endpoint = `http://127.0.0.1:${port}/json/list`;
  let response: Response;
  try {
    response = await fetch(endpoint);
  } catch (err) {
    throw new Error(
      `bun-webview: HTTP request to ${endpoint} failed: ` +
        `${err instanceof Error ? err.message : String(err)}`,
    );
  }
  if (!response.ok) {
    throw new Error(
      `bun-webview: ${endpoint} returned HTTP status ${response.status} ${response.statusText}`.trim(),
    );
  }
  const body = await response.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch (err) {
    throw new Error(
      `bun-webview: ${endpoint} returned HTTP status ${response.status} with a body that is not JSON: ` +
        `${err instanceof Error ? err.message : String(err)}`,
    );
  }
  if (!Array.isArray(parsed)) {
    throw new Error(
      `bun-webview: ${endpoint} returned HTTP status ${response.status} with ` +
        `${typeof parsed}, expected an array of targets`,
    );
  }
  return parsed as CdpTarget[];
}

/**
 * Poll `expr` in the page until it is truthy. Errors from evaluate are kept and
 * reported in the timeout message rather than discarded -- during load an
 * expression can legitimately throw before the DOM it names exists.
 */
export async function waitFor(
  view: WebView,
  expr: string,
  opts: WaitForOptions = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const intervalMs = opts.intervalMs ?? 100;
  const started = Bun.nanoseconds();
  const elapsedMs = () => (Bun.nanoseconds() - started) / 1e6;
  let lastError: unknown;

  for (;;) {
    try {
      if (await view.evaluate(expr)) return;
      lastError = undefined;
    } catch (err) {
      lastError = err;
    }
    if (elapsedMs() >= timeoutMs) break;
    await Bun.sleep(Math.min(intervalMs, Math.max(0, timeoutMs - elapsedMs())));
    if (elapsedMs() >= timeoutMs) {
      // One last look, so a short timeout still gets a fair final evaluation.
      try {
        if (await view.evaluate(expr)) return;
        lastError = undefined;
      } catch (err) {
        lastError = err;
      }
      break;
    }
  }

  const because =
    lastError === undefined
      ? "it stayed falsy"
      : `it kept throwing: ${lastError instanceof Error ? lastError.message : String(lastError)}`;
  throw new Error(
    `bun-webview: waitFor timed out after ${elapsedMs().toFixed(0)}ms ` +
      `(limit ${timeoutMs}ms) waiting for ${expr} -- ${because}`,
  );
}

/** Width and height straight out of a PNG's IHDR chunk. */
function pngDimensions(bytes: Uint8Array): { width: number; height: number } {
  const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (const [i, byte] of SIGNATURE.entries()) {
    if (bytes[i] !== byte) {
      throw new Error(`bun-webview: screenshot is not a PNG (byte ${i} = ${bytes[i]})`);
    }
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

/**
 * Render an HTML document to a PNG file and return its real pixel size.
 *
 * The width is a correctness property, not a cosmetic one: aerc's
 * herdr-graphics filter CROPS rather than scales, so a render even one pixel
 * wide of the request shows a cut edge. The dimensions returned are read back
 * out of the encoded PNG rather than echoed from the request.
 *
 * The HTML is loaded as a data: URL, which gives it an opaque origin -- the
 * markup can be attacker-supplied (a mail body), and a file:// origin would
 * hand it a filesystem-shaped one for no benefit.
 */
export async function renderHtmlToPng(
  html: string,
  opts: RenderHtmlToPngOptions = {},
): Promise<RenderHtmlToPngResult> {
  const width = opts.width ?? 800;
  const height = opts.height ?? 600;
  const path =
    opts.path ??
    `${require("node:os").tmpdir()}/bun-webview-${Bun.hash(html).toString(16)}-${Date.now()}.png`;

  const dataUrl = `data:text/html;charset=utf-8;base64,${Buffer.from(html, "utf8").toString("base64")}`;

  const view = await openView({ width, height, headless: true });
  try {
    await view.navigate(dataUrl);
    await waitFor(view, "document.readyState === 'complete'", { timeoutMs: 30_000 });
    const shot = (await view.screenshot({ format: "png", encoding: "buffer" })) as Uint8Array;
    const size = pngDimensions(shot);
    await Bun.write(path, shot);
    return { path, width: size.width, height: size.height };
  } finally {
    // Always, including the error path: a view left open keeps the browser
    // subprocess alive and hangs the caller.
    view.close();
  }
}
