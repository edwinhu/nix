---
name: aerc-scroll-gif
description: "ALWAYS use when the question is whether aerc's `o` viewer (terminal-browser on aerc's own terminal via :exec-tty) scrolls smoothly — 'record a gif of the scroll', 'show me the scroll', 'is it smooth now', 'does o still lag', 'send me a gif of aerc', 'screen-record aerc', 'check scroll latency after the rebuild', or any /dev run touching the o viewer, its frame transport, or aerc-mail-tty. Records the herdr window, GIFs it, and has Gemini grade the video. NOT for still screenshots of a rendered mail (check-o-term-shot.sh) or the pytest e2e gate (test-aerc-o-term.sh)."
---

# aerc-scroll-gif

One command does the whole thing — its own aerc in a new herdr tab, an HTML mail opened with
`o`, gpu-screen-recorder on the herdr window while it scrolls, a GIF, and a Gemini review of the
**video** (native video understanding — the GIF is for the human, never for the reviewer):

```bash
S=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts/record-scroll.sh
setsid nohup bash "$S" --query 'from:arcteryx' --out /home/eh/nix/.craft/scroll-$(date +%H%M) \
  > /home/eh/nix/.craft/scroll.log 2>&1 < /dev/null &
```

Then arm a `Monitor` on `<out>/report.md` for the literal line `DONE` (the script's last write) and
read the report. The verdict is **computed, not judged**: changed frames per wheel detent
(`ffprobe` scene filter) — ≥3.0 smooth (an eased detent paints several frames), ≥1.5
mostly-smooth, else choppy; the changed-frame timestamps are printed so the cadence is visible.
Exit code 0/1/2 mirrors it; 3 is a pipeline failure, including "no motion captured" (input never
reached the page — not a choppy verdict). Gemini's read of the mp4 follows as advisory prose.
`--keep-tab` leaves the aerc tab open; `--no-review` skips Gemini; `--verdict-json` writes
`verdict.json` with the numbers. `--input keys` (j/space/k) can only ever grade choppy.

**Which medium do the frames reach the terminal in? `--input egress`** runs aerc under `script(1)`,
holds ↓ 3 s and parses every kitty `a=T` command written: exit 0 iff all are `t=f`/`t=s` and
< 1 KB per frame, 2 if inline pixels, 3 if none captured. The medium is terminal-browser's choice
now, not aerc's: it probes the terminal and picks File, Shared or Inline, and herdr advertises file
frames so `t=f` wins locally. `TERMINAL_BROWSER_FRAMES=inline` forces pixels into the escape stream
— required over `herdr --remote`, where a file path into this machine's `~/.tmp` is unreadable and
the pane stays blank. The transport is fixed when the SHARED daemon starts, so `terminal-browser
shutdown` before switching. `scripts/check-egress-built.sh` runs it against the freshly built aerc.

**Lag, not frame rate, is what the user feels — measure it with `--input tap-latency`**: eight
single ↓ taps 1.5 s apart under a 60 fps recording, latency = first CHANGED PIXEL after each tap
(`judge-pixels.py`), median; exit 0 iff ≤ `LAT_MAX` (200 ms), 1 sluggish, 2 laggy, 3 unmeasured.
`--surface plain` runs the same taps on terminal-browser straight into the pane — the reference.
Measured 2026-09-21: plain **236 ms**, aerc `o` **293 ms**, so aerc's own overhead is ~57 ms and
the rest is terminal-browser's.

**Pixels are the verdict; `a=T` counting is not.** `judge-taps.py` still reports an announcement
median beside it (`announceMedianMs` in `verdict.json`) and it is advisory only: on one run it said
137 ms "fast" with three taps it could not see while pixels said 293 ms "sluggish". terminal-browser
renders into mmap'd ring files and a repaint emits NO syscall, so anything counting writes is timing
handoffs rather than paint. The harness shuts the shared terminal-browser daemon down first — a
stale one makes the pixel writer invisible.

Deliver: `SendUserFile` the GIF **only once the verdict is `smooth`** — a GIF sent before the
verdict is a claim of smoothness nobody checked. Otherwise send the report's problem timestamps.

## Facts you cannot derive from the tools

- The bash-allowlist hook in `farmOutOnly` projects refuses `hyprctl`, `ffmpeg`,
  `gpu-screen-recorder`, `notmuch` from the main thread — run the script detached as above; a
  foreground call is refused before it starts.
- The herdr window's ghostty title is the **active pane's name** (`omarchy: assistant`), not
  "herdr" — the script picks the most recently focused ghostty client; matching on "herdr" finds
  nothing.
- `gpu-screen-recorder -region` wants **logical** compositor coordinates (what `hyprctl` reports);
  scaling to physical pixels yourself doubles the region on a HiDPI monitor.
- `~/.nix-profile/bin/aerc` is a PATH wrapper; the Go binary is `bin/.aerc-wrapped`. Grepping the
  wrapper for a symbol proves nothing about the deployed build.
- Kitty frames take ~7 s to arrive after `o`; recording earlier captures a blank pane and the
  reviewer grades nothing.
- Only the **wheel** is eased. On Linux terminal-browser has no native scroll helper, so the
  launcher's preload (`aerc-html-terminal-browser.nix`) swallows each 120 px detent and animates
  it over rAF frames; `j`/`k`/`d`/`u`/space/arrows are `scrollBy({behavior:"instant"})` by
  design. Measured 2026-09-12: a keys recording graded "choppy — exact 224 px single-frame jumps,
  zero lag, zero tearing" — that is the pager keys working as written, not a renderer defect.
  The script's `--input wheel` is a REAL wheel (ydotool over uinput, pointer parked in the viewer
  by `hyprctl dispatch movecursor`); SGR mouse reports written into aerc's tty measured nothing
  usable (6.8 s of no motion, then coalesced jumps).
- Measured 2026-09-12 against the RETIRED in-aerc kitty relay (removed in 8332f3f), kept because
  the per-frame cost it isolates still applies: changed frames arrived in 1–2
  frame clusters every ~320 ms whatever the detent cadence — **~3 frames/s** under continuous
  scrolling, 27 changed frames for 28 detents. Each frame is clean (no tearing, no lag); there is
  simply no next frame for a third of a second. The 8 ms debounce removal was ~3 % of that; the
  per-frame pipeline cost (child render → kitty frame → terminal upload) is the lever.
- Gemini (agy) left to itself writes frame-analysis scripts and runs past look-at's print timeout
  without a verdict; the prompt now forbids scripting and the verdict never depends on it.
- Omarchy ships `omarchy-capture-screenshot` (grim+slurp) and `omarchy-capture-screenrecording`
  (gpu-screen-recorder, mp4); no wf-recorder, wl-screenrec, asciinema or gifski. asciinema-style
  terminal capture cannot see kitty graphics at all.

## Red flags — STOP

| About to | Do instead |
|---|---|
| Send keys to the user's own aerc pane | the script starts its own aerc in a tab it creates and closes |
| Record the whole monitor, or `grim` a burst of stills | `-w region` on the herdr window at 60 fps; stills cannot show easing |
| Hand the GIF to the reviewer | the mp4 goes to look-at; a 30 fps GIF hides the stutter you are asking about |
| Send the GIF before reading the verdict | read `verdict:` in report.md first |
| Gate a /dev run on the prose review | use the exit code / `verdict.json` — `references/dev-lens.md` |

## In a /dev run

`references/dev-lens.md` — the `mechanicalChecks` entry (decidable: exit code) and the optional
advisory lens prompt for o-viewer work.
