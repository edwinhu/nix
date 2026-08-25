#!/usr/bin/env bash
# The mail-preview port did not also rewrite the HTML-to-markdown filter.
#
# Round 1 of this run smuggled a pandoc change and a new Lua filter into the
# same diff: `-t gfm` became `-t gfm-raw_html --strip-comments --lua-filter=...`,
# and the filter flattens every table and deletes every image. That is a
# user-visible change to what lands in the composer, it was never asked for, and
# it shipped with no test. This check is the boundary.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
note() { echo "assert-no-pandoc-drift: $*" >&2; fail=1; }

diff=$(git diff HEAD -- hosts/linux/omarchy/default.nix)

for token in mailHtmlToMdFilter gfm-raw_html strip-comments lua-filter; do
  if grep -q -- "$token" <<<"$diff"; then
    note "the working diff still introduces '$token' — out of scope for the port"
  fi
done

if git ls-files --others --cached --exclude-standard | grep -q 'mail-html2md\.lua'; then
  note "a mail-html2md.lua filter is present — out of scope for the port"
fi

# The original invocation must survive untouched.
if ! grep -q -- '-f html -t gfm' hosts/linux/omarchy/default.nix; then
  note "the original 'pandoc -f html -t gfm' invocation is gone"
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-no-pandoc-drift: ok -- mailHtmlToMd is untouched by this port"
