// Measure WHEEL smoothness in a running terminal-browser, page-side, over CDP.
//
// The pager-keys preload swallows each wheel event and eases the same distance over rAF frames,
// because Linux has no native scroll helper (pixel-core/build.rs compiles it only on darwin) and
// the wheel would otherwise land as one coarse 120px jump. Whether that easing is actually running
// is the question this answers, and it needs no screen recording: a rAF sampler inside the page
// records every distinct scroll position, so N positions per tick IS the easing.
//
// Usage: bun wheel-probe.ts [--ticks N] [--port P] [--min-steps M]
// Exit 0 when the median tick eases over >= min-steps positions, 1 when it does not, 3 on error.
// Prints steps per tick, the median, and the total scrolled distance.

const args = process.argv.slice(2);
const flag = (name: string, dflt: number) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? Number(args[i + 1]) : dflt;
};
const TICKS = flag("ticks", 6);
const MIN_STEPS = flag("min-steps", 4);
let PORT = flag("port", 0);

async function targetWs(port: number): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  const list = (await res.json()) as Array<{ type: string; url: string; webSocketDebuggerUrl: string }>;
  const page = list.find((t) => t.type === "page" && !t.url.startsWith("devtools://"));
  if (!page) throw new Error("no page target on the cdp port");
  return page.webSocketDebuggerUrl;
}

if (!PORT) {
  // Ask terminal-browser itself which port its live browser is on.
  const proc = Bun.spawnSync([`${process.env.HOME}/.local/share/terminal-browser/app/bin/terminal-browser`, "ls", "--json"]);
  const out = JSON.parse(proc.stdout.toString() || "{}");
  PORT = out.browsers?.[0]?.cdpPort ?? 0;
  if (!PORT) { console.error("no running browser to probe (terminal-browser ls shows none)"); process.exit(3); }
}

const ws = new WebSocket(await targetWs(PORT));
let id = 0;
const pending = new Map<number, (v: any) => void>();
ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(String(ev.data));
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)!(msg); pending.delete(msg.id); }
});
await new Promise<void>((ok, bad) => {
  ws.addEventListener("open", () => ok());
  ws.addEventListener("error", () => bad(new Error("cdp websocket failed")));
});
const send = (method: string, params: Record<string, unknown> = {}) =>
  new Promise<any>((ok) => { const n = ++id; pending.set(n, ok); ws.send(JSON.stringify({ id: n, method, params })); });

const evaluate = async (expression: string) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
  return r.result?.result?.value;
};

// A rAF sampler in the page: every animation frame, record scrollY if it changed. Distinct
// positions between two wheel ticks are the eased intermediate frames.
await evaluate(`
  (() => {
    window.__wheelProbe = { samples: [], stop: false };
    const tick = () => {
      const y = window.scrollY;
      const s = window.__wheelProbe.samples;
      if (!s.length || s[s.length - 1][1] !== y) s.push([performance.now(), y]);
      if (!window.__wheelProbe.stop) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    return true;
  })()
`);

const metrics = await send("Page.getLayoutMetrics");
const vp = metrics.result?.cssLayoutViewport ?? { clientWidth: 400, clientHeight: 400 };
const x = Math.floor((vp.clientWidth ?? 400) / 2);
const y = Math.floor((vp.clientHeight ?? 400) / 2);

const marks: number[] = [];
for (let i = 0; i < TICKS; i++) {
  marks.push(await evaluate(`performance.now()`));
  await send("Input.dispatchMouseEvent", {
    type: "mouseWheel", x, y, deltaX: 0, deltaY: 120, pointerType: "mouse",
  });
  await Bun.sleep(350);          // long enough for an ease to finish before the next tick
}
await evaluate(`window.__wheelProbe.stop = true`);
const samples: Array<[number, number]> = await evaluate(`window.__wheelProbe.samples`);

if (!samples?.length) { console.error("no scroll samples: the wheel never moved the page"); process.exit(1); }

const perTick = marks.map((t0, i) => {
  const t1 = i + 1 < marks.length ? marks[i + 1] : Infinity;
  return samples.filter(([t]) => t >= t0 && t < t1).length;
});
const sorted = [...perTick].sort((a, b) => a - b);
const median = sorted[Math.floor(sorted.length / 2)];
const distance = samples[samples.length - 1][1] - samples[0][1];

console.log(`wheel ticks: ${TICKS}; eased positions per tick: ${perTick.join(" ")}`);
console.log(`median positions per tick: ${median} (target >= ${MIN_STEPS})`);
console.log(`scrolled ${distance}px over ${samples.length} distinct positions`);
ws.close();
process.exit(median >= MIN_STEPS ? 0 : 1);
