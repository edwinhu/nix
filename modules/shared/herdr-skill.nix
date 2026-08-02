# herdr agent skill — the primitive reference for the `herdr` CLI (command
# groups, agent lifecycle states, and the two footguns: bare `herdr` attaches the
# TUI instead of printing help, and probing a mutating subcommand by omitting
# arguments EXECUTES it).
#
# Sourced from the SAME flake input that provides the binary, so the doc can
# never describe a different version than the tool it documents. That matters
# here more than usual: the skill's whole job is to describe a CLI surface.
# (`inputs.herdr` is pinned to v0.7.5 in flake.nix. Its URL says
# `ogulcancelik/herdr`, which GitHub redirects to `herdrdev/herdr` — same repo,
# same v0.7.5 commit 99df3ac3. Not a second upstream.)
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
# LAYOUT NOTE, check this on every input bump: at the pinned v0.7.5 the skill is
# a single `SKILL.md` at the REPO ROOT. Upstream later moved it to
# `skills/herdr/SKILL.md` (that is the path herdr.dev's install docs and
# `npx skills add` use). Sourcing the root file is correct for THIS pin and will
# silently produce a dangling link if the input is bumped past the move without
# updating the path here — home-manager creates the symlink whether or not the
# target exists, and nothing fails until an agent tries to read the skill.
{ herdr, ... }:

let
  skillFile = "${herdr}/SKILL.md";
in
{
  home.file.".claude/skills/herdr/SKILL.md".source = skillFile;
  home.file.".agents/skills/herdr/SKILL.md".source = skillFile;
}
