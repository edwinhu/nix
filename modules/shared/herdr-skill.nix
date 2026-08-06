# herdr agent skill — the primitive reference for the `herdr` CLI (command
# groups, agent lifecycle states, and the two footguns: bare `herdr` attaches the
# TUI instead of printing help, and probing a mutating subcommand by omitting
# arguments EXECUTES it).
#
# Extracted from the BINARY ITSELF via `herdr --skill` (v0.8.0+ embeds the doc in
# the executable), so the doc cannot describe a different version than the tool it
# documents — not merely the same git rev, the same artifact. That matters here
# more than usual: the skill's whole job is to describe a CLI surface.
# (`inputs.herdr` is pinned to v0.8.0 in flake.nix. Its URL says
# `ogulcancelik/herdr`, which GitHub redirects to `herdrdev/herdr` — same repo,
# same v0.8.0 commit 346411fa. Not a second upstream.)
#
# Deliberately NOT installed by `npx skills add herdrdev/herdr --skill herdr -g`
# and NOT vendored into dotfiles:
#   - npx writes a real copy under ~/.agents and re-points ~/.claude/skills/herdr
#     at it, silently orphaning whatever was there before. Nothing warns you.
#   - dotfiles would put a third-party doc under our own version control and make
#     updates ours to pull by hand.
# Both consumers below read one store path, so they cannot drift from each other
# or from the binary. Updating is a flake input bump; nothing else moves.
#
# Claude Code only scans ~/.claude/skills — it has no knowledge of ~/.agents, so
# the first line is what makes the skill visible to it. The second serves the
# agents that DO read the shared location (codex, agy, copilot, …).
# WHY THE BINARY AND NOT THE REPO FILE: the in-repo path is not a stable contract.
# Upstream moved the skill from the repo ROOT to `skills/herdr/SKILL.md` between
# v0.7.5 and v0.8.0, and a stale `${herdr}/SKILL.md` survives that move as a
# DANGLING SYMLINK — home-manager creates the link whether or not the target
# exists, so nothing fails until an agent tries to read the skill. `herdr --skill`
# is a CLI contract and moves with the tool, so bumps stay a one-line pin change.
# (Verified at v0.8.0: `--skill` output is byte-identical to skills/herdr/SKILL.md.)
#
# Note this EXECUTES the binary at build time, so it would need rework under
# cross-compilation. Both hosts build natively today.
#
# `pkgs.herdr` (the package, via the overlay in flake.nix) — NOT the `herdr`
# specialArg, which is the flake input SOURCE and has no bin/.
{ pkgs, ... }:

let
  skillFile = pkgs.runCommand "herdr-skill.md" { } ''
    ${pkgs.herdr}/bin/herdr --skill > $out
  '';
in
{
  home.file.".claude/skills/herdr/SKILL.md".source = skillFile;
  home.file.".agents/skills/herdr/SKILL.md".source = skillFile;
}
