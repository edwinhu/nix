#!/usr/bin/env bun
// Render a mail's HTML the way the recipient will see it, inline in the terminal.
//
//     mail-preview FILE.eml            # or an MML template
//     mail-preview -a work 1234        # an existing message/draft, -m defaults to drafts
//     mail-preview --html < body.html  # bare HTML fragment on stdin
//
// This is a REAL render -- a headless Bun.WebView screenshots the HTML, chafa
// paints the PNG into the terminal -- not a text dump. That is the whole point:
// chawan and w3m tell you the words survived, and say nothing about whether the
// styling did. Reviewing agent-written mail needs the second thing.
//
// The PNG is kept and its path printed, so a preview that is too small to judge
// can be opened at full size without recomposing anything.

import { tmpdir } from "node:os";
import { existsSync, mkdtempSync, readFileSync, statSync } from "node:fs";

type RenderHtmlToPng = (
  html: string,
  opts: { width?: number; height?: number; path?: string },
) => Promise<{ path: string; width: number; height: number }>;

// The helper is a nix derivation at runtime (the wrapper exports
// BUN_WEBVIEW_LIB); the repo-relative path is only for running this file
// straight out of the working tree.
async function loadRenderer(): Promise<RenderHtmlToPng> {
  const candidates = [
    process.env.BUN_WEBVIEW_LIB,
    new URL("../../../../modules/shared/bun-webview", import.meta.url).pathname,
  ].filter((d): d is string => typeof d === "string" && d.length > 0);
  for (const dir of candidates) {
    const entry = `${dir.replace(/\/$/, "")}/index.ts`;
    if (existsSync(entry)) return (await import(entry)).renderHtmlToPng as RenderHtmlToPng;
  }
  die(
    "mail-preview: cannot find the bun-webview helper. Set BUN_WEBVIEW_LIB to the " +
      `directory holding index.ts (looked in: ${candidates.join(", ")})`,
  );
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}

// A desktop mail reading pane; narrower than a browser window. Overridable
// because the aerc herdr-graphics filter needs the PNG at an EXACT pixel width:
// herdr crops to grid_cols*cell_w rather than scaling, so any other width shows
// a cropped edge. The render window is that width exactly -- the PNG that comes
// out is what the filter measures.
const WIDTH = Number.parseInt(process.env.MAIL_PREVIEW_WIDTH ?? "900", 10) || 900;
const TALL = 6000; // render window height: a ceiling on message length, then cropped

// A wedged himalaya must not freeze the aerc pane it is previewing into, so the
// fetch is bounded rather than open-ended. Kept well inside a human's patience;
// override for a slow account or to make a test give up sooner.
const HIMALAYA_TIMEOUT_MS =
  Number.parseInt(process.env.MAIL_PREVIEW_HIMALAYA_TIMEOUT_MS ?? "", 10) || 30000;

// Neutral chrome around the message so the render shows the recipient's frame
// (white page, system font, header block) rather than the raw fragment floating
// on transparency -- which is what makes a broken background or a stray margin
// visible at all.
const page = (w: number, headers: string, body: string) => `<!doctype html><meta charset="utf-8"><style>
  html { background: #e5e5e5; }
  body { margin: 0; padding: 24px;
         font: 15px/1.5 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
         color: #1a1a1a; }
  .hdr { max-width: ${w}px; margin: 0 auto 14px; background: #fff;
         border: 1px solid #d0d0d0; border-radius: 6px 6px 0 0;
         padding: 12px 20px; font-size: 13px; color: #555; }
  .hdr b { color: #222; font-weight: 600; }
  .hdr .subj { font-size: 17px; color: #111; font-weight: 600; margin-bottom: 6px; }
  .msg { max-width: ${w}px; margin: 0 auto; background: #fff;
         border: 1px solid #d0d0d0; border-top: 0; padding: 20px; }
  .msg img { max-width: 100%; }
</style>
<div class="hdr">${headers}</div>
<div class="msg">${body}</div>
`;

// ---------------------------------------------------------------- MIME/MML --

/** Pull headers + the text/html part out of an MML template. */
function fromMml(text: string): [string, string] {
  const idx = text.search(/\n\n/);
  const head = idx === -1 ? text : text.slice(0, idx);
  const body = idx === -1 ? "" : text.slice(idx + 2);
  const parts = [...body.matchAll(/<#part type=text\/html>\n([\s\S]*?)(?:<#\/part>|$)/g)].map(
    (m) => m[1] ?? "",
  );
  return [head, parts.length ? parts.join("\n") : body];
}

interface Entity {
  headers: [string, string][];
  raw: string;
}

function headerOf(entity: Entity, name: string): string {
  const wanted = name.toLowerCase();
  for (const [k, v] of entity.headers) if (k.toLowerCase() === wanted) return v;
  return "";
}

/** Split an RFC 5322 entity into unfolded headers and its raw body. */
function parseEntity(raw: string): Entity {
  const match = raw.match(/\r?\n\r?\n/);
  const headBlock = match ? raw.slice(0, match.index) : raw;
  const body = match ? raw.slice((match.index ?? 0) + match[0].length) : "";
  const headers: [string, string][] = [];
  for (const line of headBlock.split(/\r?\n/)) {
    if (/^[ \t]/.test(line) && headers.length) {
      headers[headers.length - 1]![1] += " " + line.trim();
      continue;
    }
    const colon = line.indexOf(":");
    if (colon > 0) headers.push([line.slice(0, colon).trim(), line.slice(colon + 1).trim()]);
  }
  return { headers, raw: body };
}

function contentType(entity: Entity): { type: string; params: Record<string, string> } {
  const value = headerOf(entity, "content-type") || "text/plain";
  const [head, ...rest] = value.split(";");
  const params: Record<string, string> = {};
  for (const chunk of rest) {
    const eq = chunk.indexOf("=");
    if (eq === -1) continue;
    params[chunk.slice(0, eq).trim().toLowerCase()] = chunk
      .slice(eq + 1)
      .trim()
      .replace(/^"|"$/g, "");
  }
  return { type: (head ?? "").trim().toLowerCase(), params };
}

function decodeQuotedPrintable(text: string): Buffer {
  const out: number[] = [];
  // Soft line breaks first: `=` at end of line means "no break here".
  const joined = text.replace(/=\r?\n/g, "");
  for (let i = 0; i < joined.length; i++) {
    const ch = joined[i]!;
    if (ch === "=" && /^[0-9A-Fa-f]{2}$/.test(joined.slice(i + 1, i + 3))) {
      out.push(Number.parseInt(joined.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      // The source is already a JS string; anything non-ASCII was 8-bit clean.
      for (const byte of Buffer.from(ch, "utf8")) out.push(byte);
    }
  }
  return Buffer.from(out);
}

function decodeBytes(bytes: Buffer, charset: string): string {
  try {
    return new TextDecoder(charset || "utf-8", { fatal: false }).decode(bytes);
  } catch {
    return bytes.toString("utf8");
  }
}

/** The decoded text of a leaf entity: transfer encoding, then charset. */
function partContent(entity: Entity): string {
  const cte = headerOf(entity, "content-transfer-encoding").toLowerCase().trim();
  const charset = contentType(entity).params["charset"] ?? "utf-8";
  if (cte === "base64") {
    return decodeBytes(Buffer.from(entity.raw.replace(/\s+/g, ""), "base64"), charset);
  }
  if (cte === "quoted-printable") return decodeBytes(decodeQuotedPrintable(entity.raw), charset);
  return entity.raw;
}

function subParts(entity: Entity): Entity[] {
  const { type, params } = contentType(entity);
  const boundary = params["boundary"];
  if (!type.startsWith("multipart/") || !boundary) return [];
  const chunks = entity.raw.split(new RegExp(`\r?\n?--${escapeRegExp(boundary)}(--)?[ \t]*\r?\n?`));
  // The first chunk is the preamble and the last the epilogue; both are noise.
  return chunks
    .slice(1, -1)
    .filter((c) => c !== undefined && c !== "--" && c.trim() !== "")
    .map((c) => parseEntity(c));
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** First non-attachment part of `want`, depth first -- email.get_body's rule. */
function findPart(entity: Entity, want: string): Entity | null {
  if (/^attachment/i.test(headerOf(entity, "content-disposition"))) return null;
  const { type } = contentType(entity);
  if (type === want) return entity;
  for (const child of subParts(entity)) {
    const hit = findPart(child, want);
    if (hit) return hit;
  }
  return null;
}

/** Decode RFC 2047 encoded-words, the way email.policy.default does for display. */
function decodeEncodedWords(value: string): string {
  return value.replace(
    /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g,
    (_all, charset: string, enc: string, text: string) => {
      const bytes =
        enc.toUpperCase() === "B"
          ? Buffer.from(text, "base64")
          : decodeQuotedPrintable(text.replace(/_/g, " "));
      return decodeBytes(bytes, charset);
    },
  );
}

function fromEml(raw: string): [string, string] {
  const msg = parseEntity(raw);
  const html = findPart(msg, "text/html");
  let body: string;
  if (html) {
    body = partContent(html);
  } else {
    const plain = findPart(msg, "text/plain");
    body =
      "<pre style='white-space:pre-wrap;font:inherit'>" +
      escape(plain ? partContent(plain) : "") +
      "</pre>";
  }
  const head = msg.headers.map(([k, v]) => `${k}: ${decodeEncodedWords(v)}`).join("\n");
  return [head, body];
}

/**
 * MML templates are 7-bit clean, but a fetched draft can come back
 * quoted-printable inside the MML wrapper (himalaya does not always decode).
 */
function decodeMmlEncodings(text: string): string {
  if (/=[0-9A-F]{2}/.test(text) && text.includes("=\n")) {
    return decodeQuotedPrintable(text).toString("utf8");
  }
  return text;
}

function escape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const DISPLAY_HEADERS = ["from", "to", "cc", "bcc", "subject"];

function headerHtml(head: string): string {
  const rows: string[] = [];
  let subject = "";
  for (const line of head.split("\n")) {
    const colon = line.indexOf(":");
    if (colon <= 0) continue;
    const name = line.slice(0, colon).trim();
    const value = line.slice(colon + 1).trim();
    if (!DISPLAY_HEADERS.includes(name.toLowerCase()) || !value) continue;
    if (name.toLowerCase() === "subject") subject = escape(value);
    else rows.push(`<div><b>${escape(name)}:</b> ${escape(value)}</div>`);
  }
  return (subject ? `<div class="subj">${subject}</div>` : "") + rows.join("");
}

// ------------------------------------------------------------------ render --

async function render(head: string, body: string, outPng: string): Promise<void> {
  const renderHtmlToPng = await loadRenderer();
  // Deliberately over-tall, then cropped back: a screenshot captures the
  // WINDOW, so a short window over a long message silently cuts it in half.
  // No polling loop -- unlike headless chromium's --screenshot CLI, which never
  // exits and had to be watched by file size, a WebView awaits its own shot.
  let result: { path: string; width: number; height: number };
  try {
    result = await renderHtmlToPng(page(WIDTH, headerHtml(head), body), {
      width: WIDTH,
      height: TALL,
      path: outPng,
    });
  } catch (err) {
    die(`mail-preview: render failed: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (!existsSync(outPng) || statSync(outPng).size === 0) {
    die("mail-preview: the render produced no screenshot");
  }
  cropToContent(outPng, result.height);
}

/**
 * Trim the dead gray below the message left by the over-tall window.
 *
 * Only the BOTTOM is trimmed: a full -trim would also eat the side margins, and
 * the gray gutter is what makes the message read as a card in a client rather
 * than as a bare fragment. Cropping at the full width also keeps the exact
 * pixel width the herdr-graphics filter measures. If ImageMagick is missing the
 * preview is still correct, just padded, so this never fails the render.
 */
function cropToContent(png: string, renderedHeight: number): void {
  if (!Bun.which("magick")) return;
  const run = (args: string[]) =>
    Bun.spawnSync(["magick", ...args], { stdout: "pipe", stderr: "pipe" });
  try {
    const info = run([png, "-background", "#e5e5e5", "-fuzz", "1%", "-format", "%@", "info:"]);
    if (info.exitCode !== 0) return;
    const m = info.stdout.toString().trim().match(/(\d+)x(\d+)\+(\d+)\+(\d+)/);
    if (!m) return;
    const ch = Number(m[2]);
    const cy = Number(m[4]);
    const sizes = run([png, "-format", "%wx%h", "info:"]);
    if (sizes.exitCode !== 0) return;
    const dims = sizes.stdout.toString().trim().split("x");
    const width = Number(dims[0]);
    const full = Number(dims[1]) || renderedHeight;
    const height = Math.min(full, cy + ch + 24); // 24 = the page's own bottom padding
    if (!width || !height) return;
    run([png, "-crop", `${width}x${height}+0+0`, "+repage", png]);
  } catch {
    // A failed crop leaves a padded but correct preview; never fail the render.
  }
}

// ----------------------------------------------------------------- display --

/**
 * Text render, for use INSIDE aerc (`:pipe -m`).
 *
 * aerc's own text/html filter is chawan, so this is the same renderer the
 * message view uses -- colors, bold, links and table layout survive; images and
 * fonts do not. It exists because no pixel render works in an aerc terminal
 * tab: chafa -f kitty hangs on a /dev/tty probe aerc never answers, and -f
 * sixel draws nothing on this Ghostty build.
 */
function showChawan(head: string, body: string): void {
  const cha = process.env.CHA_HTML;
  const cmd = cha
    ? [cha]
    : ["cha", "-d", "-T", "text/html", "-I", "UTF-8", "-O", "UTF-8"];
  if (!cha && !Bun.which("cha")) die("mail-preview: no chawan (cha) on PATH");
  for (const line of head.split("\n")) {
    const colon = line.indexOf(":");
    if (colon <= 0) continue;
    const name = line.slice(0, colon).trim();
    const value = line.slice(colon + 1).trim();
    if (DISPLAY_HEADERS.includes(name.toLowerCase()) && value) console.log(`${name}: ${value}`);
  }
  console.log();
  const proc = Bun.spawnSync(cmd, { stdin: Buffer.from(body, "utf8"), stdout: "inherit", stderr: "inherit" });
  void proc;
}

/**
 * Open the PNG in its own window.
 *
 * This is the ONLY preview that works from inside aerc: aerc's embedded
 * terminal parses and DISCARDS kitty graphics escapes, so chafa output piped
 * into an aerc terminal tab is silently blank (same constraint the PDF filter
 * works around via herdr's pane-graphics).
 */
function showExternal(png: string): void {
  const viewer = ["imv", "hylo", "xdg-open"].map((b) => Bun.which(b)).find(Boolean);
  if (!viewer) {
    console.log(`rendered: ${png}`);
    return;
  }
  Bun.spawn([viewer, png], {
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
  }).unref();
}

function show(png: string): void {
  if (Bun.which("chafa")) {
    // NOT reachable from inside aerc -- aerc's embedded terminal parses and
    // discards a child's kitty escapes (and sixel), measured 0 against a plain-
    // pty control of 1 (see the [filters] note in the omarchy host). This path
    // is for a real
    // terminal; from aerc use showExternal, or `o` for Chromium. Force the
    // protocol and geometry so chafa never probes /dev/tty. Width fills the
    // pane; height remains scrollable instead of squashed.
    const cols = process.stdout.columns || 120;
    Bun.spawnSync(["chafa", "-f", "kitty", "--probe", "off", "--size", `${cols}x`, png], {
      stdout: "inherit",
      stderr: "inherit",
    });
  } else {
    console.log(`(no chafa) rendered: ${png}`);
  }
}

/**
 * The raw RFC 5322 bytes of one message, straight off himalaya's stdout.
 *
 * `message read --raw` is the v2 replacement for v1's `message export -F -d
 * <dir>`: it dumps to stdout, so there is no temp dir to manage and no file to
 * wait for. `read` without --raw would render himalaya's own header+text view,
 * which is not parseable as MIME.
 *
 * Bounded: himalaya stalled on an unreachable IMAP server would otherwise block
 * the preview forever. The Python this replaced passed timeout=120.
 */
function fetchMessage(account: string, mailbox: string, msgid: string): string {
  const r = Bun.spawnSync(
    ["himalaya", "message", "read", "--raw", "-a", account, "-m", mailbox, msgid],
    { stdout: "pipe", stderr: "pipe", timeout: HIMALAYA_TIMEOUT_MS },
  );
  if (r.exitedDueToTimeout) {
    die(
      `mail-preview: himalaya did not respond within ${HIMALAYA_TIMEOUT_MS}ms while reading ` +
        `${msgid} from ${mailbox}; giving up (override with MAIL_PREVIEW_HIMALAYA_TIMEOUT_MS)`,
    );
  }
  const out = r.stdout.toString();
  if (r.exitCode !== 0 || !out.trim()) {
    die(
      `mail-preview: could not read ${msgid} from ${mailbox}: ` +
        (r.stderr.toString().trim() || out.trim()),
    );
  }
  return out;
}

// --------------------------------------------------------------------- CLI --

interface Args {
  target?: string;
  account?: string;
  mailbox: string;
  html: boolean;
  out?: string;
  open: boolean;
  text: boolean;
  renderOnly: boolean;
}

const USAGE = `usage: mail-preview [-h] [-a ACCOUNT] [-m MAILBOX] [--html] [-o OUT] [--open]
                    [--text] [--render-only] [target]

  target         file path, or message id with -a
  -a, --account  himalaya account
  -m, --mailbox  mailbox (default: drafts)
  --html         stdin is a bare HTML fragment
  -o, --out      where to write the PNG
  --open         open in an image viewer instead of painting in the terminal
  --text         render through chawan instead (works inside aerc)
  --render-only  write the PNG and print its path; display nothing`;

function parseArgs(argv: string[]): Args {
  const args: Args = { mailbox: "drafts", html: false, open: false, text: false, renderOnly: false };
  const value = (flag: string, inline: string | undefined, i: { v: number }): string => {
    if (inline !== undefined) return inline;
    const next = argv[++i.v];
    if (next === undefined) die(`mail-preview: ${flag} needs a value`);
    return next;
  };
  const i = { v: 0 };
  for (; i.v < argv.length; i.v++) {
    const arg = argv[i.v]!;
    const eq = arg.indexOf("=");
    const name = arg.startsWith("--") && eq !== -1 ? arg.slice(0, eq) : arg;
    const inline = arg.startsWith("--") && eq !== -1 ? arg.slice(eq + 1) : undefined;
    switch (name) {
      case "-h":
      case "--help":
        console.log(USAGE);
        process.exit(0);
      case "--html":
        args.html = true;
        break;
      case "--open":
        args.open = true;
        break;
      case "--text":
        args.text = true;
        break;
      case "--render-only":
        args.renderOnly = true;
        break;
      case "-a":
      case "--account":
        args.account = value(name, inline, i);
        break;
      case "-m":
      case "--mailbox":
        args.mailbox = value(name, inline, i);
        break;
      case "-o":
      case "--out":
        args.out = value(name, inline, i);
        break;
      default:
        if (arg.startsWith("-a") && arg.length > 2) args.account = arg.slice(2);
        else if (arg.startsWith("-m") && arg.length > 2) args.mailbox = arg.slice(2);
        else if (arg.startsWith("-o") && arg.length > 2) args.out = arg.slice(2);
        else if (arg !== "-" && arg.startsWith("-")) die(`mail-preview: unknown argument ${arg}\n\n${USAGE}`);
        else if (args.target === undefined) args.target = arg;
        else die(`mail-preview: unexpected argument ${arg}\n\n${USAGE}`);
    }
  }
  return args;
}

function tempPng(): string {
  const dir = mkdtempSync(`${tmpdir()}/mail-preview.`);
  return `${dir}/mail-preview.png`;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  let head = "";
  let body: string;
  if (args.html || args.target === undefined || args.target === "-") {
    body = await Bun.stdin.text();
    if (!args.html) [head, body] = body.includes("<#part") ? fromMml(body) : fromEml(body);
  } else if (args.account && !existsSync(args.target)) {
    [head, body] = fromEml(fetchMessage(args.account, args.mailbox, args.target));
  } else {
    let raw: string;
    try {
      raw = readFileSync(args.target, "utf8");
    } catch (err) {
      die(`mail-preview: cannot read ${args.target}: ${err instanceof Error ? err.message : String(err)}`);
    }
    [head, body] = raw.includes("<#part") ? fromMml(raw) : fromEml(raw);
  }

  body = decodeMmlEncodings(body);
  if (args.text) {
    showChawan(head, body);
    return;
  }
  const png = args.out ?? tempPng();
  await render(head, body, png);
  if (args.renderOnly) {
    console.log(png);
    return;
  }
  if (args.open) {
    showExternal(png);
  } else if (!process.stdout.isTTY) {
    // Piped: nothing can be painted and a viewer window would be the wrong
    // thing, so hand the caller the path -- the same stdout contract as
    // --render-only, which is what a pipe is asking for.
    console.log(png);
  } else {
    show(png);
  }
  console.error(`\nrendered: ${png}`);
}

await main();
