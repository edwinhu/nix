#!/usr/bin/env bash
# The HTML render neither waits for nor FIRES remote subresources.
#
# Two properties, one test. The old script passed --virtual-time-budget=3000, so
# a message full of tracking pixels rendered in about three seconds. The port
# gated the screenshot on `readyState === 'complete'` with a 30s ceiling, which
# is the load event: it does not fire until every remote <img>, webfont and
# pixel has settled. That is slow AND it fires the pixels -- telling the sender
# the mail was opened, from a preview the reader never chose to trust.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib-pinned-bun.sh
. scripts/lib-pinned-bun.sh
bun=$(pinned_bun)

"$bun" - <<'TS'
const lib = process.env.BUN_WEBVIEW_LIB ?? "./modules/shared/bun-webview";
const { renderHtmlToPng } = await import(`${lib}/index.ts`);

let hits = 0;
const server = Bun.serve({
  port: 0, hostname: "127.0.0.1",
  // Never responds: a render that waits on this would hang until its ceiling.
  fetch: async () => { hits++; await Bun.sleep(120_000); return new Response("x"); },
});

const html = `<html><body><img src="http://127.0.0.1:${server.port}/pixel.png">`
  + `<p>visible text</p></body></html>`;

const started = Bun.nanoseconds();
let failed = 0;
try {
  const out = await renderHtmlToPng(html, { width: 400, height: 300 });
  const seconds = (Bun.nanoseconds() - started) / 1e9;
  console.log(`render took ${seconds.toFixed(2)}s, remote hits ${hits}, ${out.width}x${out.height}`);
  if (seconds > 10) {
    console.error(`assert-render-offline: took ${seconds.toFixed(2)}s -- it waited on the hanging resource`);
    failed = 1;
  }
  if (hits > 0) {
    console.error(`assert-render-offline: fired ${hits} remote request(s) -- mail HTML must not phone home`);
    failed = 1;
  }
  if (out.width !== 400) {
    console.error(`assert-render-offline: width ${out.width} != 400`);
    failed = 1;
  }
} catch (e) {
  console.error(`assert-render-offline: render threw: ${(e as Error).message}`);
  failed = 1;
} finally {
  server.stop(true);
}
if (failed) process.exit(1);
console.log("assert-render-offline: ok -- bounded render, no remote fetches");
TS
