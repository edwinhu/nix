// The specification for the helper. Every browser test drives a REAL headless
// Chromium against a loopback fixture server on an ephemeral port -- never the
// user's running browser, which holds their logged-in sessions on :9222/:9250.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  attachView,
  listTargets,
  openView,
  renderHtmlToPng,
  resolveChromium,
  waitFor,
} from "./index.ts";

const scratch = mkdtempSync(join(tmpdir(), "bun-webview-test-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

/** Width read straight out of the PNG IHDR: bytes 16-19, big-endian. */
function pngSize(path: string): { width: number; height: number } {
  const b = readFileSync(path);
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (const [i, byte] of signature.entries()) {
    if (b[i] !== byte) throw new Error(`${path} is not a PNG (byte ${i} = ${b[i]})`);
  }
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

function fixtureServer(body: string) {
  return Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: () => new Response(body, { headers: { "content-type": "text/html" } }),
  });
}

describe("resolveChromium", () => {
  test("returns an executable chromium path from PATH", () => {
    const path = resolveChromium();
    expect(path).toBeString();
    expect(path.length).toBeGreaterThan(0);
    expect(Bun.which(path) ?? path).toBeTruthy();
  });

  test("names every candidate it looked for when none is found", async () => {
    // Run in a SUBPROCESS with a scrubbed PATH rather than mutating
    // process.env.PATH here. A global mutation is invisible when the file runs
    // serially and poisons every browser-spawning test under `bun test
    // --concurrent`, which is how this was found.
    const probe = join(scratch, "no-chromium-probe.ts");
    writeFileSync(
      probe,
      `import { resolveChromium } from ${JSON.stringify(join(import.meta.dir, "index.ts"))};\n` +
        `try { resolveChromium(); console.log("RESOLVED"); }\n` +
        `catch (e) { console.log("THREW:" + (e as Error).message); }\n`,
    );
    const proc = Bun.spawn([process.execPath, probe], {
      env: { ...process.env, PATH: scratch }, // an empty directory: no browser reachable
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;
    const out = await new Response(proc.stdout).text();
    // Match a candidate NAME, not the word "chromium" -- the latter is a
    // substring of "resolveChromium" and would pass against a stub.
    expect(out).toContain("THREW:");
    expect(out).toMatch(/chromium-browser/);
  });
});

describe("openView", () => {
  test("renders a page and evaluates in it", async () => {
    const server = fixtureServer(
      "<html><head><title>Fixture</title></head><body><h1 id=h>hello</h1></body></html>",
    );
    let view: any;
    try {
      view = await openView({ url: `http://127.0.0.1:${server.port}/`, width: 400, height: 200 });
      await waitFor(view, "document.getElementById('h') !== null");
      expect(await view.evaluate("document.getElementById('h').textContent")).toBe("hello");
      expect(view.title).toBe("Fixture");
    } finally {
      view?.close();
      server.stop(true);
    }
  }, 60_000);

  test("spawns its own browser rather than attaching to a running one", async () => {
    // The safety property, tested behaviourally: a view opened with no explicit
    // endpoint must not be able to see the user's tabs. Its own target list is
    // exactly the page it opened. If openView silently attached to the running
    // Chromium, this page would be one of many and the fixture URL would not be
    // the only http:// target.
    const server = fixtureServer("<html><title>Isolated</title><body>alone</body></html>");
    let view: any;
    try {
      view = await openView({ url: `http://127.0.0.1:${server.port}/`, width: 300, height: 200 });
      await waitFor(view, "document.body.textContent.includes('alone')");
      const targets = await view.cdp("Target.getTargets", {});
      const pages = (targets?.targetInfos ?? [])
        .filter((t: any) => t.type === "page" && t.url.startsWith("http"));
      // Our own page is there...
      expect(pages.some((t: any) => t.url.startsWith(`http://127.0.0.1:${server.port}`))).toBe(true);
      // ...and NOTHING from outside this test run is. That is the actual safety
      // property. Counting `pages.length === 1` was the old assertion and it is
      // not concurrency-stable: under `bun test --concurrent`, Bun reuses one
      // browser process across views in the same test process, so a sibling
      // test's fixture page shows up in this target list. Loopback-only is true
      // either way, and still fails immediately if the view ever joined the
      // user's real browser.
      const foreign = pages.filter((t: any) => !/^https?:\/\/127\.0\.0\.1:/.test(t.url));
      expect(foreign.map((t: any) => t.url)).toEqual([]);
    } finally {
      view?.close();
      server.stop(true);
    }
  }, 60_000);
});

describe("waitFor", () => {
  test("resolves once the expression becomes truthy", async () => {
    const server = fixtureServer(
      "<html><body><script>setTimeout(()=>{window.ready=true},300)</script></body></html>",
    );
    let view: any;
    try {
      view = await openView({ url: `http://127.0.0.1:${server.port}/`, width: 200, height: 100 });
      await waitFor(view, "window.ready === true", { timeoutMs: 15_000 });
      expect(await view.evaluate("window.ready")).toBe(true);
    } finally {
      view?.close();
      server.stop(true);
    }
  }, 60_000);

  test("throws on timeout, naming the expression", async () => {
    const server = fixtureServer("<html><body>static</body></html>");
    let view: any;
    try {
      view = await openView({ url: `http://127.0.0.1:${server.port}/`, width: 200, height: 100 });
      const started = Bun.nanoseconds();
      await expect(
        waitFor(view, "window.neverSetByAnyone === true", { timeoutMs: 700, intervalMs: 50 }),
      ).rejects.toThrow(/neverSetByAnyone/);
      // It waited rather than failing instantly.
      expect((Bun.nanoseconds() - started) / 1e6).toBeGreaterThan(500);
    } finally {
      view?.close();
      server.stop(true);
    }
  }, 60_000);
});

describe("renderHtmlToPng", () => {
  test("writes a PNG whose width is exactly the width requested", async () => {
    // Exactness matters: aerc's herdr-graphics filter CROPS rather than scales,
    // so a render one pixel off shows a cut edge.
    const path = join(scratch, "render.png");
    const result = await renderHtmlToPng(
      "<html><body style='margin:0'><div style='height:120px'>body</div></body></html>",
      { width: 640, height: 400, path },
    );
    expect(result.path).toBe(path);
    expect(pngSize(path).width).toBe(640);
    expect(result.width).toBe(640);
  }, 60_000);

  test("a different requested width produces a different PNG width", async () => {
    // Guards the assertion above against a hard-coded 640.
    const path = join(scratch, "narrow.png");
    await renderHtmlToPng("<html><body>x</body></html>", { width: 320, height: 200, path });
    expect(pngSize(path).width).toBe(320);
  }, 60_000);
});

describe("listTargets", () => {
  test("parses a /json/list payload", async () => {
    const payload = [
      { id: "A", type: "page", title: "One", url: "https://example.invalid/",
        webSocketDebuggerUrl: "ws://127.0.0.1:1/devtools/page/A" },
    ];
    const server = Bun.serve({
      port: 0, hostname: "127.0.0.1",
      fetch: (req) =>
        new URL(req.url).pathname === "/json/list"
          ? Response.json(payload)
          : new Response("no", { status: 404 }),
    });
    try {
      const targets = await listTargets(server.port);
      expect(targets).toHaveLength(1);
      expect(targets[0].id).toBe("A");
      expect(targets[0].webSocketDebuggerUrl).toBe("ws://127.0.0.1:1/devtools/page/A");
    } finally {
      server.stop(true);
    }
  });

  test("fails loudly when the endpoint is not a CDP endpoint", async () => {
    const server = Bun.serve({
      port: 0, hostname: "127.0.0.1",
      fetch: () => new Response("not json", { status: 500 }),
    });
    try {
      // The message must describe the failure, not merely be a throw: a stub
      // that throws "not implemented" would otherwise satisfy this.
      // Deliberately avoids the words "list"/"target": an unimplemented stub
      // throws a message containing its own export name, which would match.
      await expect(listTargets(server.port)).rejects.toThrow(/500|status|http/i);
    } finally {
      server.stop(true);
    }
  });
});

describe("attachView", () => {
  test("is exported and refuses an endpoint that is not there", async () => {
    // Attaching must be a deliberate, named act -- never something openView does
    // by default. Its failure mode on a dead endpoint must be an error.
    expect(attachView).toBeFunction();
    await expect(
      attachView("ws://127.0.0.1:1/devtools/browser/nope"),
      // Same trap: "attach" would match the stub's own message.
    ).rejects.toThrow(/ws:\/\/|connect|refused|endpoint|econnrefused/i);
  }, 30_000);
});
