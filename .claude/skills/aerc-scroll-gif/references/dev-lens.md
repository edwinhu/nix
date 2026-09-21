# Using the scroll recording in a /dev run

The decidable form is a **mechanical check** — the script's exit code is the verdict (0 smooth,
1 mostly-smooth, 2 choppy, 3 pipeline failure or no motion captured), computed from changed
frames per real wheel detent (≥3.0 / ≥1.5 / below), so the JS gate reads a number and no agent
asserts a pass. Baseline on 2026-09-12: 0.96 frames per detent → choppy, exit 2 — a run whose
gate includes this check starts red and must move the per-frame pipeline cost to go green. Add to the plan's `craft:dispatch` block and its Run sizing line:

```json
{"name": "scroll-smooth",
 "cmd": "bash /home/eh/nix/.claude/skills/aerc-scroll-gif/scripts/record-scroll.sh --query from:arcteryx --verdict-json --out /home/eh/nix/.craft/scroll-check"}
```

```
Mechanical checks: scroll-smooth — `bash /home/eh/nix/.claude/skills/aerc-scroll-gif/scripts/record-scroll.sh --query from:arcteryx --verdict-json --out /home/eh/nix/.craft/scroll-check`
```

What it needs, and why each is load-bearing:

- **A live herdr session and a visible desktop.** The probe agent inherits the dispatching pane's
  `HERDR_*` env, so a craft run dispatched from a herdr pane can run it; a headless or SSH dispatch
  cannot, and the check reads as exit 3 — a pipeline failure, never a pass.
- **The deployed aerc, not the checkout.** It records whatever `aerc` on PATH is, i.e. the profile
  after `build-switch`. Run it as the check of a run whose gate already passed and was deployed
  (`nix-build-aerc` proves the build; this proves the feel), or point PATH at
  `.craft/o-term-build/aerc/bin` first.
- **Under the 10-minute cap:** ~2 minutes end to end (7 s render wait, ~12 s scroll, ffmpeg, two
  Gemini calls). `craft-result.sh` re-runs it once to adjudicate the claim — so two recordings per
  round, both opening and closing a tab in the user's herdr.
- **Judged → decidable:** the reviewer is told to end with one `VERDICT:` line; the script parses
  that line only. The prose stays in `report.md` for the human; the gate never reads it.

## Optional advisory lens

For the passthrough, paint-on-drain or aerc-mail-term work, a lens that reads the report the
mechanical check already produced (so no second recording):

```json
{"key": "scroll-smoothness", "agentType": "Explore", "refs": [],
 "prompt": "Read /home/eh/nix/.craft/scroll-check/report.md (written by the scroll-smooth mechanical check this round). MAJOR at most — advisory. Report a finding only if the reviewer's VERDICT is not smooth, naming the timestamps and the symptom it describes (stutter, dropped frames, lag behind keypress cadence), and relating it to what this run changed in widgets/term/term.go or ansi/parser.go. If the report is missing or ends without DONE, report that the check did not run — never read absence as smooth."}
```

Keep it advisory (MAJOR cap): the exit code already gates; the lens exists to attach the
reviewer's timestamps to the code that moved.
